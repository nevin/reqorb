import 'package:flutter/foundation.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/protocols/grpc_session.dart';
import 'package:reqorb/protocols/ws_session.dart';
import 'package:reqorb/request/request_draft.dart';
import 'package:reqorb/request/send_session.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// One open request: what is being edited, where it is saved, and the
/// conversation each kind of request has with its server. Several can be
/// open at once, each keeping its own response.
class RequestTab {
  RequestTab(Engine engine, WorkspaceStore store, {String url = ''})
    : _startUrl = url,
      draft = RequestDraft(url: url),
      http = SendSession(engine, store),
      ws = WsSession(engine),
      grpc = GrpcSession(engine);

  static int _count = 0;

  /// Tells this tab from every other, however they are reordered.
  final int id = _count++;

  /// The address the tab started with, which counts as nothing written.
  final String _startUrl;

  final RequestDraft draft;
  final SendSession http;
  final WsSession ws;
  final GrpcSession grpc;

  /// The saved request being edited, if the tab was opened from one.
  RequestRef? origin;

  /// The name the saved request had when it was opened or last saved, by
  /// which it is recognised after the list it is in has changed.
  String? savedName;

  /// The name given to a request that has not been saved yet.
  String? draftName;

  /// Which part of the request is showing: params, headers and so on.
  int section = 0;

  /// Notifies when any of the tab's conversations moves on.
  late final Listenable sessions = Listenable.merge([http, ws, grpc]);

  /// Whether the request differs from its saved copy. One that was never
  /// saved has nothing to differ from.
  bool get dirty => origin != null && draft.dirty;

  /// Whether the tab is as a new one is: nothing written, nothing sent,
  /// nothing saved. Such a tab can be given to whatever is opened next.
  bool get blank {
    if (origin != null || http.sent != null || http.sending) return false;
    final request = draft.toRequest();
    return request.method == 'GET' &&
        request.url == _startUrl &&
        request.headers.isEmpty &&
        request.body == null &&
        request.form.isEmpty &&
        request.auth == null &&
        request.settings == null &&
        request.tests.isEmpty &&
        request.captures.isEmpty &&
        request.preScript == null &&
        request.postScript == null;
  }

  /// What the tab is called when its request has no name: the path of
  /// its address, or failing that the address itself.
  String get fallbackLabel {
    final url = draft.url.text.trim();
    if (url.isEmpty) return 'Untitled';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.path.isEmpty || uri.path == '/' ? uri.host : uri.path;
  }

  void dispose() {
    draft.dispose();
    http.dispose();
    ws.dispose();
    grpc.dispose();
  }
}
