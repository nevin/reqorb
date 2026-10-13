/// The app's one doorway to the Rust engine.
library;

import 'package:flutter/widgets.dart' hide FormField;
import 'package:reqorb/src/rust/api/core.dart' as rust;
import 'package:reqorb/src/rust/api/core.dart';

/// Everything the app asks of the engine: sending, importing, exporting and
/// keeping the workspace on disk. Widgets reach it through [Engine.of], so
/// that tests can put a stand-in in its place and run without the native
/// library.
abstract class Engine {
  const Engine();

  /// The engine provided by the nearest [EngineScope].
  static Engine of(BuildContext context) {
    // Read without subscribing: the engine is fixed for the app's lifetime,
    // and this way it can be asked for before a widget's first build.
    final scope = context.getInheritedWidgetOfExactType<EngineScope>();
    assert(scope != null, 'No EngineScope above this widget');
    return scope!.engine;
  }

  // ---------------------------------------------------------------- sending

  Future<Sent> sendRequest({
    required Request request,
    required List<Variable> variables,
    required Settings settings,
    required List<Cookie> cookies,
  });

  /// Like [sendRequest], reporting the response while it arrives: first
  /// its head, then its body in pieces, and last how the send ended.
  /// [id] names the send, for [cancelSend].
  Stream<SendUpdate> sendWatched({
    required int id,
    required Request request,
    required List<Variable> variables,
    required Settings settings,
    required List<Cookie> cookies,
  });

  /// Stops a watched send; false when it has already ended. One whose
  /// body was arriving ends with what had arrived.
  bool cancelSend({required int id});

  /// Opens a WebSocket known by [id]; its events arrive on the stream.
  Stream<WsEvent> wsOpen({
    required int id,
    required Request request,
    required List<Variable> variables,
  });

  /// Sends a text message; false when the connection is not open.
  bool wsSend({required int id, required String text});

  /// Asks the connection to close; false when it is not open.
  bool wsClose({required int id});

  Future<GrpcSchema> grpcReflect({
    required String url,
    required List<Header> metadata,
    Auth? auth,
    required List<Variable> variables,
  });

  Future<GrpcSchema> grpcLoadProto({required String path});

  Future<GrpcReply> grpcCall({
    required GrpcCall call,
    required List<Variable> variables,
  });

  // ---------------------------------------------------------------- graphql

  /// Fetches the schema of the GraphQL server [request] points at.
  Future<GraphQlSchema> graphqlSchema({
    required Request request,
    required List<Variable> variables,
    required Settings settings,
    required List<Cookie> cookies,
  });

  /// The operations a query names, and what is wrong with it, if anything.
  GraphQlQuery graphqlInspect({required String query});

  /// The query with consistent indentation; throws when it cannot be read.
  String graphqlFormat({required String query});

  /// A query for one field of the schema's `query`, `mutation` or
  /// `subscription` type.
  GraphQlDraft? graphqlDraft({
    required GraphQlSchema schema,
    required String kind,
    required String field,
  });

  // ------------------------------------------------------------ description

  List<AuthChoice> authChoices();

  /// The settings a new workspace, and a request with none of its own,
  /// start from.
  Settings defaultSettings();
  RequestSettings defaultRequestSettings();
  List<AuthField> authFields({required AuthKind kind});

  // -------------------------------------------------------------- workspace

  /// Tries a folder out: whether it is there, can be listed and written to.
  DirAccess checkDirectory({required String path});

  /// Reads the workspace, decrypting its credentials with the key in the
  /// system keychain.
  Future<LoadedWorkspace> loadWorkspace({required String path});

  /// Writes the workspace. Returns why its credentials were left
  /// unencrypted, when its settings asked for them to be and the keychain
  /// could not be used.
  Future<String?> saveWorkspace({
    required String path,
    required Workspace workspace,
  });

  /// How many values in the workspace are still encrypted, for want of
  /// the key.
  int lockedSecrets({required Workspace workspace});

  // ---------------------------------------------------------------- history

  /// The requests sent before, oldest first.
  Future<LoadedHistory> loadHistory({required String path});

  /// Adds [entries] to the history, keeping about [limit] in all and
  /// encrypting them when [protect] is set.
  Future<void> appendHistory({
    required String path,
    required List<HistoryEntry> entries,
    required int limit,
    required bool protect,
  });
  Future<void> clearHistory({required String path});

  // ------------------------------------------------------ import and export

  Future<ImportResult> importText({
    required String text,
    required String nameHint,
  });
  Future<ImportResult> importUrl({required String url});
  Future<ImportResult> importHar({
    required String text,
    required String name,
    required List<int> entries,
  });
  Future<String> exportCollection({
    required Collection collection,
    required ExportFormat format,
  });
  Future<String> exportEnvironment({
    required Environment environment,
    required ExportFormat format,
  });
  String exportExtension({required ExportFormat format});
  String exportHar({required List<Exchange> exchanges});

  /// The languages a request can be written out in.
  List<CodeChoice> codeChoices();

  /// The request as code, with [variables] filled in; throws for a request
  /// that is not HTTP.
  String generateCode({
    required Request request,
    required List<Variable> variables,
    required CodeTarget target,
  });

  /// The rows of a CSV or JSON data file, each as the variables it sets
  /// for one time through a run; throws when the file cannot be read.
  List<List<Variable>> parseRunData({
    required String name,
    required String text,
  });
  Future<HarReport> analyzeHar({required String text});

  // -------------------------------------------------------------- redaction

  List<Exchange> redactExchanges({required List<Exchange> exchanges});
  Collection redactCollection({required Collection collection});
  Environment redactEnvironment({required Environment environment});
  String redactText({required String text});
}

/// Makes an [Engine] available to the widgets below it.
class EngineScope extends InheritedWidget {
  const EngineScope({super.key, required this.engine, required super.child});

  final Engine engine;

  @override
  bool updateShouldNotify(EngineScope oldWidget) => engine != oldWidget.engine;
}

/// The real engine: the Rust library, through the generated bridge.
class RustEngine extends Engine {
  const RustEngine();

  @override
  Future<Sent> sendRequest({
    required Request request,
    required List<Variable> variables,
    required Settings settings,
    required List<Cookie> cookies,
  }) => rust.sendRequest(
    request: request,
    variables: variables,
    settings: settings,
    cookies: cookies,
  );

  @override
  Stream<SendUpdate> sendWatched({
    required int id,
    required Request request,
    required List<Variable> variables,
    required Settings settings,
    required List<Cookie> cookies,
  }) => rust.sendRequestWatched(
    id: id,
    request: request,
    variables: variables,
    settings: settings,
    cookies: cookies,
  );

  @override
  bool cancelSend({required int id}) => rust.cancelSend(id: id);

  @override
  Stream<WsEvent> wsOpen({
    required int id,
    required Request request,
    required List<Variable> variables,
  }) => rust.wsOpen(id: id, request: request, variables: variables);

  @override
  bool wsSend({required int id, required String text}) =>
      rust.wsSend(id: id, text: text);

  @override
  bool wsClose({required int id}) => rust.wsClose(id: id);

  @override
  Future<GrpcSchema> grpcReflect({
    required String url,
    required List<Header> metadata,
    Auth? auth,
    required List<Variable> variables,
  }) => rust.grpcReflect(
    url: url,
    metadata: metadata,
    auth: auth,
    variables: variables,
  );

  @override
  Future<GrpcSchema> grpcLoadProto({required String path}) =>
      rust.grpcLoadProto(path: path);

  @override
  Future<GraphQlSchema> graphqlSchema({
    required Request request,
    required List<Variable> variables,
    required Settings settings,
    required List<Cookie> cookies,
  }) => rust.graphqlSchema(
    request: request,
    variables: variables,
    settings: settings,
    cookies: cookies,
  );

  @override
  GraphQlQuery graphqlInspect({required String query}) =>
      rust.graphqlInspect(query: query);

  @override
  String graphqlFormat({required String query}) =>
      rust.graphqlFormat(query: query);

  @override
  GraphQlDraft? graphqlDraft({
    required GraphQlSchema schema,
    required String kind,
    required String field,
  }) => rust.graphqlDraft(schema: schema, kind: kind, field: field);

  @override
  Future<GrpcReply> grpcCall({
    required GrpcCall call,
    required List<Variable> variables,
  }) => rust.grpcCall(call: call, variables: variables);

  @override
  List<AuthChoice> authChoices() => rust.authChoices();

  @override
  Settings defaultSettings() => rust.defaultSettings();

  @override
  RequestSettings defaultRequestSettings() => rust.defaultRequestSettings();

  @override
  List<AuthField> authFields({required AuthKind kind}) =>
      rust.authFields(kind: kind);

  @override
  DirAccess checkDirectory({required String path}) =>
      rust.checkDirectory(path: path);

  @override
  Future<LoadedWorkspace> loadWorkspace({required String path}) =>
      rust.loadWorkspace(path: path);

  @override
  Future<String?> saveWorkspace({
    required String path,
    required Workspace workspace,
  }) => rust.saveWorkspace(path: path, workspace: workspace);

  @override
  int lockedSecrets({required Workspace workspace}) =>
      rust.lockedSecrets(workspace: workspace);

  @override
  Future<LoadedHistory> loadHistory({required String path}) =>
      rust.loadHistory(path: path);

  @override
  Future<void> appendHistory({
    required String path,
    required List<HistoryEntry> entries,
    required int limit,
    required bool protect,
  }) => rust.appendHistory(
    path: path,
    entries: entries,
    limit: limit,
    protect: protect,
  );

  @override
  Future<void> clearHistory({required String path}) =>
      rust.clearHistory(path: path);

  @override
  Future<ImportResult> importText({
    required String text,
    required String nameHint,
  }) => rust.importText(text: text, nameHint: nameHint);

  @override
  Future<ImportResult> importUrl({required String url}) =>
      rust.importUrl(url: url);

  @override
  Future<ImportResult> importHar({
    required String text,
    required String name,
    required List<int> entries,
  }) => rust.importHar(text: text, name: name, entries: entries);

  @override
  Future<String> exportCollection({
    required Collection collection,
    required ExportFormat format,
  }) => rust.exportCollection(collection: collection, format: format);

  @override
  Future<String> exportEnvironment({
    required Environment environment,
    required ExportFormat format,
  }) => rust.exportEnvironment(environment: environment, format: format);

  @override
  String exportExtension({required ExportFormat format}) =>
      rust.exportExtension(format: format);

  @override
  String exportHar({required List<Exchange> exchanges}) =>
      rust.exportHar(exchanges: exchanges);

  @override
  List<CodeChoice> codeChoices() => rust.codeChoices();

  @override
  String generateCode({
    required Request request,
    required List<Variable> variables,
    required CodeTarget target,
  }) =>
      rust.generateCode(request: request, variables: variables, target: target);

  @override
  List<List<Variable>> parseRunData({
    required String name,
    required String text,
  }) => rust.parseRunData(name: name, text: text);

  @override
  Future<HarReport> analyzeHar({required String text}) =>
      rust.analyzeHar(text: text);

  @override
  List<Exchange> redactExchanges({required List<Exchange> exchanges}) =>
      rust.redactExchanges(exchanges: exchanges);

  @override
  Collection redactCollection({required Collection collection}) =>
      rust.redactCollection(collection: collection);

  @override
  Environment redactEnvironment({required Environment environment}) =>
      rust.redactEnvironment(environment: environment);

  @override
  String redactText({required String text}) => rust.redactText(text: text);
}
