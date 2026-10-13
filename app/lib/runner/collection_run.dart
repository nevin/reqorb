import 'package:flutter/foundation.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/request/send_session.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// One request of a run, with where it sits in what is being run.
class RunStep {
  const RunStep(this.path, this.request, this.collection);

  /// `Folder/Name`, from the collection or folder being run.
  final String path;
  final Request request;

  /// The collection whose variables the request can use, if it is in one.
  final int? collection;

  /// Whether the runner can send it. WebSocket and gRPC requests hold a
  /// conversation, which a run has no one to carry on.
  bool get runnable => request.method != 'WS' && request.method != 'GRPC';
}

/// The requests under [items], depth first, as a run takes them.
List<RunStep> runSteps(
  List<Item> items,
  int? collection, [
  String prefix = '',
]) {
  final steps = <RunStep>[];
  for (final item in items) {
    final path = prefix.isEmpty ? item.name : '$prefix/${item.name}';
    if (item.request case final request?) {
      steps.add(RunStep(path, request, collection));
    }
    steps.addAll(runSteps(item.items, collection, path));
  }
  return steps;
}

/// How one request of a run came out.
class RunResult {
  const RunResult(this.step, this.iteration, {this.sent, this.error});

  final RunStep step;

  /// Which time through the requests this was, from 0.
  final int iteration;
  final Sent? sent;

  /// Why nothing came back, when nothing did.
  final String? error;

  /// Tests decide when the request has any; otherwise the status does,
  /// along with the errors of a GraphQL response.
  bool get passed {
    final sent = this.sent;
    if (sent == null) return false;
    if (sent.tests.isEmpty) {
      return sent.response.status < 400 && sent.graphqlErrors.isEmpty;
    }
    return sent.tests.every((t) => t.passed);
  }

  int get testsFailed => sent?.tests.where((t) => !t.passed).length ?? 0;
}

/// Sends a list of requests one after another, as a browser session would:
/// cookies and captured values pass from each to the next.
class CollectionRun extends ChangeNotifier {
  CollectionRun(this._engine, this._store);

  final Engine _engine;
  final WorkspaceStore _store;

  final results = <RunResult>[];
  bool running = false;

  /// How many requests the run set out to send.
  int planned = 0;

  /// Set when the run ended before sending everything, with the reason.
  String? endedEarly;

  /// How long the run took, or has taken so far.
  Duration elapsed = Duration.zero;

  bool _stop = false;
  bool _disposed = false;

  int get failed => results.where((r) => !r.passed).length;
  int get tests => results.fold(0, (n, r) => n + (r.sent?.tests.length ?? 0));
  int get testsFailed => results.fold(0, (n, r) => n + r.testsFailed);

  /// Goes through [steps] once for each of [rows], whose variables outrank
  /// the environment's and the collection's. A value captured during the
  /// run outranks them all.
  Future<void> start(
    List<RunStep> steps, {
    List<List<Variable>> rows = const [[]],
    Duration delay = Duration.zero,
    bool stopOnFailure = false,
  }) async {
    if (running) return;
    running = true;
    _stop = false;
    endedEarly = null;
    results.clear();
    planned = steps.length * rows.length;
    elapsed = Duration.zero;
    final clock = Stopwatch()..start();
    _notify();

    final captured = <Variable>[];
    run:
    for (final (iteration, row) in rows.indexed) {
      for (final step in steps) {
        if (results.isNotEmpty && delay > Duration.zero) {
          await Future<void>.delayed(delay);
        }
        if (_stop) {
          endedEarly = 'Stopped';
          break run;
        }
        final result = await _send(step, iteration, [
          ...captured,
          ...row,
          ..._store.variablesFor(step.collection),
        ]);
        for (final variable
            in (result.sent?.captured ?? const <Variable>[]).reversed) {
          captured
            ..removeWhere((v) => v.key == variable.key)
            ..insert(0, variable);
        }
        results.add(result);
        elapsed = clock.elapsed;
        _notify();
        if (!result.passed && stopOnFailure) {
          endedEarly = 'Stopped at the first failure';
          break run;
        }
      }
    }
    elapsed = clock.elapsed;
    running = false;
    _notify();
  }

  Future<RunResult> _send(
    RunStep step,
    int iteration,
    List<Variable> variables,
  ) async {
    final request = step.request;
    try {
      final sent = await _engine.sendRequest(
        request: readdressed(request, withScheme(request.url)),
        variables: variables,
        settings: _store.settings,
        cookies: _store.cookies,
      );
      _store.setCookies(sent.cookies);
      _store.record(sent.exchanges, source: request, name: step.path);
      _store.capture(sent.captured);
      return RunResult(step, iteration, sent: sent);
    } catch (e) {
      return RunResult(step, iteration, error: e.toString());
    }
  }

  /// Ends the run once the request in flight has been answered.
  void stop() {
    if (!running) return;
    _stop = true;
    _notify();
  }

  bool get stopping => running && _stop;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop = true;
    super.dispose();
  }
}
