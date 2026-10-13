import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// [url] with `http://` in front when it names no scheme. A leading
/// variable is left alone, as it usually holds the scheme already.
String withScheme(String url) =>
    url.contains('://') || url.startsWith('{{') ? url : 'http://$url';

/// [request] addressed to [url], and otherwise the same.
Request readdressed(Request request, String url) => Request(
  method: request.method,
  url: url,
  headers: request.headers,
  body: request.body,
  bodyMode: request.bodyMode,
  form: request.form,
  graphqlVariables: request.graphqlVariables,
  graphqlOperation: request.graphqlOperation,
  auth: request.auth,
  settings: request.settings,
  tests: request.tests,
  captures: request.captures,
);

/// Whether a response of this type is a stream, read as it arrives
/// rather than once it is whole.
bool isStreamType(String contentType) {
  final mime = contentType.split(';').first.trim().toLowerCase();
  return const {
    'text/event-stream',
    'application/x-ndjson',
    'application/ndjson',
    'application/jsonl',
    'application/stream+json',
  }.contains(mime);
}

String _contentTypeOf(List<Header> headers) {
  for (final header in headers) {
    if (header.name.toLowerCase() == 'content-type') return header.value;
  }
  return '';
}

/// Sending the open HTTP request and holding what came back.
class SendSession extends ChangeNotifier {
  SendSession(this._engine, this._store);

  final Engine _engine;
  final WorkspaceStore _store;

  /// Names each send to the engine, across every session.
  static int _ids = 0;

  /// A body that is not a stream is shown as it arrives only up to this
  /// size; a larger one is counted, and shown once it is whole.
  static const _liveLimit = 256 * 1024;

  bool sending = false;

  /// Whether a response has begun and its body is still arriving.
  bool receiving = false;

  /// Whether the response shown was cut short by [cancel].
  bool stopped = false;

  /// The last response, kept while the next one is on its way. While
  /// [receiving] it holds as much of the new one as has arrived.
  Sent? sent;

  /// Why the last send failed, if it did.
  String? error;

  /// Identifies the send in flight, so a cancelled one is ignored on return.
  int _current = 0;
  int? _engineId;
  bool _disposed = false;

  // The response in flight.
  SendUpdate? _head;
  final _text = StringBuffer();
  int _received = 0;
  bool _stopping = false;
  final _clock = Stopwatch();
  Timer? _tick;

  /// Sends [request], which must have a URL. Cookies, the session log and
  /// captured variables are kept even if the result is no longer wanted.
  ///
  /// [name] is what the request is saved as, for the history.
  Future<void> send(
    Request request,
    List<Variable> variables, {
    String name = '',
  }) async {
    if (sending) return;
    final url = withScheme(request.url);
    final id = ++_current;
    final engineId = _engineId = _ids++;
    sending = true;
    receiving = false;
    stopped = false;
    error = null;
    _head = null;
    _stopping = false;
    _clock
      ..reset()
      ..start();
    _notify();

    void end() {
      if (id != _current) return;
      _tick?.cancel();
      _clock.stop();
      sending = false;
      receiving = false;
      _engineId = null;
      _notify();
    }

    void failed(String message) {
      if (id != _current) return;
      // A send stopped between two responses has nothing whole to show.
      error = _stopping ? null : message;
      sent = null;
      end();
    }

    try {
      await for (final update in _engine.sendWatched(
        id: engineId,
        request: readdressed(request, url),
        variables: variables,
        settings: _store.settings,
        cookies: _store.cookies,
      )) {
        switch (update.kind) {
          case SendUpdateKind.head:
            if (id != _current) continue;
            _head = update;
            _text.clear();
            _received = 0;
            receiving = true;
            _show();
          case SendUpdateKind.body:
            if (id != _current) continue;
            _received = update.received;
            if (_live) _text.write(update.text);
            // Many small pieces are shown together, a few times a second.
            _tick ??= Timer(const Duration(milliseconds: 100), _show);
          case SendUpdateKind.done:
            final result = update.sent!;
            // Keep whatever the server set, even if this send was abandoned.
            _store.setCookies(result.cookies);
            _store.record(result.exchanges, source: request, name: name);
            _store.capture(result.captured);
            if (id != _current) continue;
            sent = result;
            stopped = _stopping;
            end();
          case SendUpdateKind.failed:
            failed(update.text);
        }
      }
    } catch (e) {
      failed(e.toString());
    }
    // A stream that closed without saying how it ended.
    if (id == _current && sending) failed('The send ended unexpectedly');
  }

  /// Whether the body in flight is shown piece by piece.
  bool get _live =>
      isStreamType(_contentTypeOf(_head?.headers ?? const [])) ||
      _received <= _liveLimit;

  /// How much of the response in flight has arrived, in bytes.
  int get received => _received;

  /// Puts what has arrived of the response in flight on show.
  void _show() {
    _tick = null;
    final head = _head;
    if (head == null || !receiving) return;
    sent = Sent(
      response: Response(
        status: head.status,
        statusText: head.statusText,
        httpVersion: head.httpVersion,
        headers: head.headers,
        body: _live ? _text.toString() : '',
        sizeBytes: _received,
        elapsedMs: _clock.elapsedMilliseconds,
      ),
      unresolved: const [],
      cookies: const [],
      exchanges: const [],
      tests: const [],
      captured: const [],
      captureProblems: const [],
      graphqlErrors: const [],
    );
    _notify();
  }

  /// Shows a response from the history in place of a fresh one.
  void show(Exchange exchange) {
    _abandon();
    error = null;
    stopped = false;
    sent = Sent(
      response: exchange.response,
      unresolved: const [],
      cookies: const [],
      exchanges: [exchange],
      tests: const [],
      captured: const [],
      captureProblems: const [],
      graphqlErrors: const [],
    );
    _notify();
  }

  /// Stops the request in flight. One whose body is arriving ends with
  /// what has arrived, which is how a stream that never ends is left;
  /// one still waiting for an answer is dropped.
  void cancel() {
    if (!sending) return;
    if (receiving) {
      _stopping = true;
      if (_engineId case final id?) _engine.cancelSend(id: id);
      return;
    }
    _abandon();
    _notify();
  }

  /// Forgets the response, as when another request is opened. A send still
  /// in flight is abandoned, so its response cannot appear under that one.
  void reset() {
    _abandon();
    sent = null;
    error = null;
    stopped = false;
    _notify();
  }

  /// Lets go of the send in flight, telling the engine to stop it.
  void _abandon() {
    _current++;
    _tick?.cancel();
    _tick = null;
    if (_engineId case final id? when sending) _engine.cancelSend(id: id);
    _engineId = null;
    sending = false;
    receiving = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _abandon();
    _disposed = true;
    super.dispose();
  }
}
