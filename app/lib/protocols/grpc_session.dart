import 'package:flutter/foundation.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/src/rust/api/core.dart';

/// A gRPC server's methods, once known, and the last call made to it.
class GrpcSession extends ChangeNotifier {
  GrpcSession(this._engine);

  final Engine _engine;

  /// The server's methods, loaded by reflection or from a `.proto` file.
  GrpcSchema? schema;

  /// Whether the methods are being loaded or a call is in flight.
  bool busy = false;
  GrpcReply? reply;
  String? error;

  /// Whether a call is in flight, and whether any of its responses have
  /// arrived, in which case [reply] holds them so far.
  bool calling = false;
  bool receiving = false;

  /// Names each call to the engine, across every session.
  static int _ids = 0;
  int? _callId;

  /// Bumped by [reset], so that work started for one request does not
  /// report into the next.
  int _epoch = 0;
  bool _disposed = false;

  /// Loads the methods from [proto], or from the server at [request]'s
  /// address when it is null. Returns them, or null if that failed or
  /// another request was opened meanwhile.
  Future<GrpcSchema?> load({
    String? proto,
    required Request request,
    required List<Variable> variables,
  }) async {
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      final loaded = proto != null
          ? await _engine.grpcLoadProto(path: proto)
          : await _engine.grpcReflect(
              url: request.url,
              metadata: request.headers,
              auth: request.auth,
              variables: variables,
            );
      if (epoch != _epoch) return null;
      schema = loaded;
      busy = false;
      _notify();
      return loaded;
    } catch (e) {
      if (epoch != _epoch) return null;
      busy = false;
      reply = null;
      error = e.toString();
      _notify();
      return null;
    }
  }

  /// Calls [method] with [messages]. Responses are shown as they arrive,
  /// which is how a server stream is followed. The methods must have been
  /// loaded.
  Future<void> call({
    required Request request,
    required String method,
    required List<String> messages,
    required List<Variable> variables,
  }) async {
    final known = schema;
    if (busy || known == null) return;
    final epoch = _epoch;
    final id = _callId = _ids++;
    busy = true;
    calling = true;
    receiving = false;
    error = null;
    _notify();
    final clock = Stopwatch()..start();
    final arrived = <String>[];

    void end() {
      if (epoch != _epoch) return;
      busy = false;
      calling = false;
      receiving = false;
      _callId = null;
      _notify();
    }

    void failed(String message) {
      if (epoch != _epoch) return;
      reply = null;
      error = message;
      end();
    }

    try {
      await for (final update in _engine.grpcCallWatched(
        id: id,
        call: GrpcCall(
          url: request.url,
          method: method,
          messages: messages,
          metadata: request.headers,
          auth: request.auth,
          descriptors: known.descriptors,
        ),
        variables: variables,
      )) {
        if (epoch != _epoch) continue;
        if (update.message case final message?) {
          arrived.add(message);
          receiving = true;
          // What has come so far, until the call ends and says how.
          reply = GrpcReply(
            code: 0,
            status: 'OK',
            message: '',
            messages: [...arrived],
            headers: const [],
            trailers: const [],
            elapsedMs: clock.elapsedMilliseconds,
          );
          _notify();
        } else if (update.reply case final result?) {
          reply = result;
          end();
        } else {
          failed(update.error ?? 'The call ended unexpectedly');
        }
      }
    } catch (e) {
      failed(e.toString());
    }
    if (epoch == _epoch && calling && _callId == id) {
      failed('The call ended unexpectedly');
    }
  }

  /// Ends the call in flight, keeping the responses it had.
  void stop() {
    if (_callId case final id? when calling) _engine.grpcCancel(id: id);
  }

  /// Forgets the methods and the last call, as when another request is opened.
  void reset() {
    stop();
    _epoch++;
    schema = null;
    busy = false;
    calling = false;
    receiving = false;
    _callId = null;
    reply = null;
    error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}
