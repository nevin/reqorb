import 'dart:async';
import 'dart:typed_data';

import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/src/rust/api/core.dart';

Response response({int status = 200, String body = '{"ok":true}'}) => Response(
  status: status,
  statusText: status == 200 ? 'OK' : 'Not Found',
  httpVersion: 'HTTP/1.1',
  headers: const [Header(name: 'content-type', value: 'application/json')],
  body: body,
  sizeBytes: body.length,
  elapsedMs: 12,
);

Sent sentWith(
  Response response, {
  List<TestResult> tests = const [],
  List<Variable> captured = const [],
}) => Sent(
  response: response,
  unresolved: const [],
  cookies: const [],
  exchanges: const [],
  tests: tests,
  captured: captured,
  captureProblems: const [],
);

WsEvent wsEvent(WsEventKind kind, [String text = '']) => WsEvent(
  kind: kind,
  text: text,
  data: Uint8List(0),
  code: kind == WsEventKind.open ? 101 : 0,
  headers: const [],
  atMs: 0,
);

/// Stands in for the Rust engine. It records what it is asked and answers
/// from what the test set up; anything else is an error.
class FakeEngine extends Engine {
  // ------------------------------------------------------------------ http

  /// Every request sent, with the variables it was sent with.
  final sends = <(Request, List<Variable>)>[];

  /// The app settings each send was made with.
  final sentSettings = <Settings>[];

  /// Answers a send. Replace it to fail, or to answer later.
  Future<Sent> Function(Request request) onSend = (_) async =>
      sentWith(response());

  @override
  Future<Sent> sendRequest({
    required Request request,
    required List<Variable> variables,
    required Settings settings,
    required List<Cookie> cookies,
  }) {
    sends.add((request, variables));
    sentSettings.add(settings);
    return onSend(request);
  }

  // ------------------------------------------------------------- websocket

  /// Connections opened, by id, with the request each was opened for.
  final sockets = <int, StreamController<WsEvent>>{};
  final socketRequests = <int, Request>{};
  final wsSent = <String>[];

  /// Whether a connection reports itself open as soon as it is asked for.
  bool wsAccepts = true;

  @override
  Stream<WsEvent> wsOpen({
    required int id,
    required Request request,
    required List<Variable> variables,
  }) {
    final socket = StreamController<WsEvent>();
    sockets[id] = socket;
    socketRequests[id] = request;
    if (wsAccepts) socket.add(wsEvent(WsEventKind.open, 'Switching Protocols'));
    return socket.stream;
  }

  bool _isOpen(int id) => wsAccepts && !(sockets[id]?.isClosed ?? true);

  @override
  bool wsSend({required int id, required String text}) {
    if (!_isOpen(id)) return false;
    wsSent.add(text);
    return true;
  }

  @override
  bool wsClose({required int id}) {
    if (!_isOpen(id)) return false;
    sockets[id]!
      ..add(wsEvent(WsEventKind.closed, 'closed by client'))
      ..close();
    return true;
  }

  // ------------------------------------------------------------------ grpc

  GrpcSchema schema = GrpcSchema(
    methods: const [
      GrpcMethod(
        path: 'shop.Orders/Get',
        clientStreaming: false,
        serverStreaming: false,
        example: '{"id": 0}',
      ),
      GrpcMethod(
        path: 'shop.Orders/Watch',
        clientStreaming: false,
        serverStreaming: true,
        example: '{}',
      ),
    ],
    descriptors: Uint8List(0),
  );
  Object? grpcFailure;
  final grpcCalls = <GrpcCall>[];
  final protoPaths = <String>[];
  int reflections = 0;

  @override
  Future<GrpcSchema> grpcReflect({
    required String url,
    required List<Header> metadata,
    Auth? auth,
    required List<Variable> variables,
  }) async {
    reflections++;
    if (grpcFailure case final failure?) throw failure;
    return schema;
  }

  @override
  Future<GrpcSchema> grpcLoadProto({required String path}) async {
    protoPaths.add(path);
    return schema;
  }

  @override
  Future<GrpcReply> grpcCall({
    required GrpcCall call,
    required List<Variable> variables,
  }) async {
    grpcCalls.add(call);
    if (grpcFailure case final failure?) throw failure;
    return GrpcReply(
      code: 0,
      status: 'OK',
      message: '',
      messages: ['{"id":1,"total":9.5}'],
      headers: const [],
      trailers: const [],
      elapsedMs: 7,
    );
  }

  // ----------------------------------------------------------- description

  @override
  List<AuthChoice> authChoices() => const [
    AuthChoice(kind: AuthKind.none, label: 'No Auth'),
    AuthChoice(kind: AuthKind.bearer, label: 'Bearer Token'),
  ];

  @override
  Settings defaultSettings() => const Settings(
    theme: AppTheme.system,
    httpMode: HttpMode.auto,
    timeoutSecs: 0,
    maxResponseMb: 0,
    verifySsl: true,
    followRedirects: true,
    sendNoCache: false,
    confirmDiscard: true,
    layout: Layout.auto,
    fontSize: 13,
    indent: Indent.twoSpaces,
    proxy: ProxyMode.system,
    proxyUrl: '',
    workingDir: '',
    workingDirGrant: '',
    allowOutsideWorkingDir: false,
  );

  @override
  RequestSettings defaultRequestSettings() => const RequestSettings(
    verifySsl: true,
    followRedirects: true,
    followOriginalMethod: false,
    followAuthHeader: false,
    removeReferer: false,
    strictHttpParser: false,
    disableCookieJar: false,
    maxRedirects: 10,
    disabledTls: DisabledTls.none,
  );

  @override
  List<AuthField> authFields({required AuthKind kind}) => switch (kind) {
    AuthKind.bearer => const [
      AuthField(
        key: 'token',
        label: 'Token',
        secret: true,
        multiline: false,
        options: [],
        defaultValue: '',
        hint: '',
      ),
    ],
    _ => const [],
  };

  // ------------------------------------------------------------- workspace

  /// What a folder allows, by path; one not listed does not exist.
  final directories = <String, DirAccess>{};

  @override
  DirAccess checkDirectory({required String path}) =>
      directories[path] ??
      const DirAccess(exists: false, readable: false, writable: false);

  /// What was last written, as the app would find it on the next launch.
  Workspace? saved;

  @override
  Future<Workspace> loadWorkspace({required String path}) async =>
      saved ?? (throw StateError('no workspace saved'));

  @override
  Future<void> saveWorkspace({
    required String path,
    required Workspace workspace,
  }) async => saved = workspace;

  // ------------------------------------------- not needed by the tests yet

  @override
  String exportHar({required List<Exchange> exchanges}) => '{"log":{}}';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeEngine has no ${invocation.memberName}');
}
