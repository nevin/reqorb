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

  /// Calls [method] with [messages] and waits for every response. The
  /// methods must have been loaded.
  Future<void> call({
    required Request request,
    required String method,
    required List<String> messages,
    required List<Variable> variables,
  }) async {
    final known = schema;
    if (busy || known == null) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await _engine.grpcCall(
        call: GrpcCall(
          url: request.url,
          method: method,
          messages: messages,
          metadata: request.headers,
          auth: request.auth,
          descriptors: known.descriptors,
        ),
        variables: variables,
      );
      if (epoch != _epoch) return;
      reply = result;
    } catch (e) {
      if (epoch != _epoch) return;
      reply = null;
      error = e.toString();
    } finally {
      if (epoch == _epoch) {
        busy = false;
        _notify();
      }
    }
  }

  /// Forgets the methods and the last call, as when another request is opened.
  void reset() {
    _epoch++;
    schema = null;
    busy = false;
    reply = null;
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
