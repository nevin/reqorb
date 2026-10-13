import 'package:flutter/foundation.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// Sending the open HTTP request and holding what came back.
class SendSession extends ChangeNotifier {
  SendSession(this._engine, this._store);

  final Engine _engine;
  final WorkspaceStore _store;

  bool sending = false;

  /// The last response, kept while the next one is on its way.
  Sent? sent;

  /// Why the last send failed, if it did.
  String? error;

  /// Identifies the send in flight, so a cancelled one is ignored on return.
  int _current = 0;
  bool _disposed = false;

  /// Sends [request], which must have a URL. Cookies, the session log and
  /// captured variables are kept even if the result is no longer wanted.
  Future<void> send(Request request, List<Variable> variables) async {
    if (sending) return;
    // A leading variable usually holds the scheme already.
    final url = request.url.contains('://') || request.url.startsWith('{{')
        ? request.url
        : 'http://${request.url}';
    final id = ++_current;
    sending = true;
    error = null;
    _notify();
    try {
      final result = await _engine.sendRequest(
        request: Request(
          method: request.method,
          url: url,
          headers: request.headers,
          body: request.body,
          bodyMode: request.bodyMode,
          form: request.form,
          auth: request.auth,
          settings: request.settings,
          tests: request.tests,
          captures: request.captures,
        ),
        variables: variables,
        settings: _store.settings,
        cookies: _store.cookies,
      );
      // Keep whatever the server set, even if this send was abandoned.
      _store.setCookies(result.cookies);
      _store.addExchanges(result.exchanges);
      _store.capture(result.captured);
      // Cancelled, or overtaken by a later send.
      if (id != _current) return;
      sent = result;
    } catch (e) {
      if (id != _current) return;
      sent = null;
      error = e.toString();
    } finally {
      if (id == _current) {
        sending = false;
        _notify();
      }
    }
  }

  /// Stops waiting for the request in flight; its response is discarded.
  void cancel() {
    _current++;
    sending = false;
    _notify();
  }

  /// Forgets the response, as when another request is opened. A send still
  /// in flight is abandoned, so its response cannot appear under that one.
  void reset() {
    _current++;
    sending = false;
    sent = null;
    error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
