import 'package:flutter/foundation.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/request/send_session.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// The schemas of the GraphQL servers asked so far, by address.
class GraphqlSession extends ChangeNotifier {
  GraphqlSession(this._engine, this._store);

  final Engine _engine;
  final WorkspaceStore _store;

  final _schemas = <String, GraphQlSchema>{};

  /// The address whose schema is being fetched, if any.
  String? loading;

  /// Why the last fetch failed, if it did.
  String? error;

  bool _disposed = false;

  /// The schema of the server at [url], once it has been fetched.
  GraphQlSchema? schemaFor(String url) => _schemas[url.trim()];

  /// Asks the server [request] points at for its schema, with the
  /// request's own headers and authorization. Returns it, or null if the
  /// server would not say; [error] then holds why.
  Future<GraphQlSchema?> fetch(
    Request request,
    List<Variable> variables,
  ) async {
    final url = request.url.trim();
    if (loading != null) return null;
    loading = url;
    error = null;
    _notify();
    try {
      final schema = await _engine.graphqlSchema(
        // Addressed as a send would be, so both reach the same server.
        request: readdressed(request, withScheme(url)),
        variables: variables,
        settings: _store.settings,
        cookies: _store.cookies,
      );
      _schemas[url] = schema;
      return schema;
    } catch (e) {
      error = e.toString();
      return null;
    } finally {
      loading = null;
      _notify();
    }
  }

  /// Forgets the last failure, as when another request is opened. Schemas
  /// are kept: they belong to servers, not to requests.
  void reset() {
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
