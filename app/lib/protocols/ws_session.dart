import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/protocols/ws_view.dart';
import 'package:reqorb/src/rust/api/core.dart';

/// One WebSocket connection and the conversation on it.
class WsSession extends ChangeNotifier {
  WsSession(this._engine);

  final Engine _engine;

  /// Connections are numbered across the app, as the engine knows them by id.
  static int _next = 1;

  /// The connection this session opened, if any.
  int? _id;
  StreamSubscription<WsEvent>? _events;
  bool _disposed = false;

  bool open = false;
  bool connecting = false;

  /// Everything sent and received, oldest first.
  final log = <WsEntry>[];

  /// Connects to the address in [request], which must have one. Headers,
  /// authorization and settings go with the handshake.
  void connect(Request request, List<Variable> variables) {
    final url = request.url.contains('://') || request.url.startsWith('{{')
        ? request.url
        : 'ws://${request.url}';
    final id = _next++;
    _id = id;
    connecting = true;
    _notify();
    _events = _engine
        .wsOpen(
          id: id,
          request: Request(
            method: 'GET',
            url: url,
            headers: request.headers,
            form: const [],
            auth: request.auth,
            settings: request.settings,
            tests: const [],
            captures: const [],
          ),
          variables: variables,
        )
        .listen(
          (event) {
            if (id != _id) return;
            connecting = false;
            if (event.kind == WsEventKind.open) open = true;
            if (event.kind == WsEventKind.closed ||
                event.kind == WsEventKind.error) {
              open = false;
            }
            log.add(WsEntry.received(event));
            _notify();
          },
          onDone: () {
            if (id != _id) return;
            open = false;
            connecting = false;
            _notify();
          },
        );
  }

  /// Closes the connection, or gives up on one still being opened.
  void disconnect() {
    final id = _id;
    if (id == null) return;
    // An open connection reports its own closing; one that never opened
    // has nothing more to say.
    if (!_engine.wsClose(id: id)) {
      _events?.cancel();
      _id = null;
      open = false;
      connecting = false;
      _notify();
    }
  }

  /// Sends [text] if the connection is open and there is something to send.
  void send(String text) {
    final id = _id;
    if (id == null || !open || text.isEmpty) return;
    if (_engine.wsSend(id: id, text: text)) {
      log.add(WsEntry.sent(text));
      _notify();
    }
  }

  void clearLog() {
    log.clear();
    _notify();
  }

  /// Drops the connection and its log, as when another request is opened.
  void reset() {
    _close();
    log.clear();
    _notify();
  }

  void _close() {
    final id = _id;
    if (id != null) _engine.wsClose(id: id);
    _events?.cancel();
    _id = null;
    _events = null;
    open = false;
    connecting = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _close();
    super.dispose();
  }
}
