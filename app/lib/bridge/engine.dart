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

  Future<Workspace> loadWorkspace({required String path});
  Future<void> saveWorkspace({
    required String path,
    required Workspace workspace,
  });

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
  Future<Workspace> loadWorkspace({required String path}) =>
      rust.loadWorkspace(path: path);

  @override
  Future<void> saveWorkspace({
    required String path,
    required Workspace workspace,
  }) => rust.saveWorkspace(path: path, workspace: workspace);

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
