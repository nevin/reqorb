import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late WorkspaceStore store;

  /// Shows the whole app on a desktop-sized window, with a stand-in engine.
  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
    store = WorkspaceStore('unused.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    // The workspace is written a moment after each change; let that finish
    // before the test ends.
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
  }

  Future<void> enterUrl(WidgetTester tester, String url) =>
      tester.enterText(find.byKey(const Key('url')), url);

  Future<void> tapSend(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String method) async {
    await tester.tap(find.byKey(const Key('method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(method).last);
    await tester.pumpAndSettle();
  }

  testWidgets('sends the request and shows the response', (tester) async {
    await open(tester);
    await enterUrl(tester, 'api.test/items?page=2');
    await tapSend(tester);

    final (request, _) = engine.sends.single;
    expect(
      (request.method, request.url),
      ('GET', 'http://api.test/items?page=2'),
    );
    expect(find.text('200 OK'), findsOneWidget);
    expect(find.textContaining('"ok"'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('asks for a URL instead of sending nothing', (tester) async {
    await open(tester);
    await enterUrl(tester, '');
    await tapSend(tester);
    expect(engine.sends, isEmpty);
    expect(find.text('Enter a URL to send the request'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('explains a request that could not be sent', (tester) async {
    await open(tester);
    engine.onSend = (_) async => throw 'could not connect: refused';
    await enterUrl(tester, 'https://down.test');
    await tapSend(tester);
    expect(find.text('The request could not be sent'), findsOneWidget);
    expect(find.text('could not connect: refused'), findsOneWidget);
  });

  testWidgets('shows how the tests came out and passes captures on', (
    tester,
  ) async {
    await open(tester);
    engine.onSend = (_) async => sentWith(
      response(),
      tests: const [
        TestResult(test: 'status == 200', passed: true, detail: ''),
        TestResult(test: 'time < 1', passed: false, detail: 'was 12'),
      ],
      captured: const [
        Variable(key: 'token', value: 't-1', enabled: true, secret: false),
      ],
    );
    await enterUrl(tester, 'https://api.test/login');
    await tapSend(tester);
    expect(find.text('Tests (1/2)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('test-results-tab')));
    await tester.pumpAndSettle();
    expect(find.textContaining('was 12'), findsOneWidget);
    expect(find.textContaining('token = t-1'), findsOneWidget);

    // The next request is sent with what this one captured.
    engine.onSend = (_) async => sentWith(response());
    await tapSend(tester);
    final (_, variables) = engine.sends.last;
    expect(variables.single.key, 'token');
  });

  testWidgets('sends and saves a request with its scripts', (tester) async {
    await open(tester);
    await enterUrl(tester, 'https://api.test/login');
    // The last of the tabs, which a narrow pane scrolls to.
    await tester.ensureVisible(find.byKey(const Key('scripts-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scripts-tab')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pre-script')),
      "vars.set('n', 1);",
    );
    await tester.enterText(
      find.byKey(const Key('post-script')),
      "test('ok', () => {});\nconsole.log('seen');",
    );
    await tester.pumpAndSettle();

    engine.onSend = (_) async => sentWith(
      response(),
      tests: const [TestResult(test: 'ok', passed: true, detail: '')],
      console: const ['seen', 'error: and this'],
    );
    await tapSend(tester);
    // The scripts go with the request, for the engine to run.
    final (sent, _) = engine.sends.single;
    expect(sent.preScript, "vars.set('n', 1);");
    expect(sent.postScript, "test('ok', () => {});\nconsole.log('seen');");

    // What they printed is shown with how the tests came out.
    expect(find.text('Tests (1/1)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('test-results-tab')));
    await tester.pumpAndSettle();
    expect(find.text('Console'), findsOneWidget);
    expect(find.byKey(const Key('console-1')), findsOneWidget);

    // Emptied, a script is not kept as an empty one.
    await tester.enterText(find.byKey(const Key('pre-script')), '  ');
    await tester.pumpAndSettle();
    await tapSend(tester);
    expect(engine.sends.last.$1.preScript, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holds a WebSocket conversation', (tester) async {
    await open(tester);
    await choose(tester, 'WS');
    await enterUrl(tester, 'echo.test/ws');
    expect(find.text('Connect'), findsOneWidget);
    await tapSend(tester);
    expect(engine.socketRequests.values.single.url, 'ws://echo.test/ws');
    expect(find.text('Disconnect'), findsOneWidget);

    await tester.tap(find.byKey(const Key('body-tab')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ws-message')), 'hello');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ws-send')));
    engine.sockets.values.single.add(wsEvent(WsEventKind.text, 'HELLO'));
    await tester.pumpAndSettle();
    expect(engine.wsSent, ['hello']);
    expect(find.text('HELLO'), findsOneWidget);
    expect(find.text('2 messages'), findsOneWidget);

    await tapSend(tester);
    expect(find.text('Connect'), findsOneWidget);
    // Once in the log, once as the connection's status.
    expect(find.textContaining('Disconnected'), findsWidgets);
    // No HTTP request was made along the way.
    expect(engine.sends, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loads a gRPC server\'s methods and calls one', (tester) async {
    await open(tester);
    await choose(tester, 'GRPC');
    await enterUrl(tester, 'localhost:50051');
    // The first press loads the methods, picks the first and calls it.
    await tapSend(tester);

    expect(engine.reflections, 1);
    final call = engine.grpcCalls.single;
    expect((call.url, call.method), ('localhost:50051', 'shop.Orders/Get'));
    expect(call.messages, ['{"id": 0}']);
    expect(find.textContaining('9.5'), findsOneWidget);
    expect(find.byKey(const Key('grpc-error')), findsNothing);

    // The methods are kept, so the next call does not ask again.
    await tapSend(tester);
    expect((engine.reflections, engine.grpcCalls.length), (1, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('follows a gRPC server stream and stops it', (tester) async {
    await open(tester);
    final updates = StreamController<GrpcUpdate>();
    late int callId;
    engine.onGrpcWatch = (id, _) {
      callId = id;
      return updates.stream;
    };
    await choose(tester, 'GRPC');
    await enterUrl(tester, 'localhost:50051');
    await tester.tap(find.byKey(const Key('send')));
    // The spinner never settles, so the frames are counted out.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Calling…'), findsOneWidget);

    // Each response is on show as soon as it arrives.
    updates.add(const GrpcUpdate(message: '{"n": 1}'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('grpc-receiving')), findsOneWidget);
    expect(find.text('Messages (1)'), findsOneWidget);
    updates.add(const GrpcUpdate(message: '{"n": 2}'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Messages (2)'), findsOneWidget);

    // Stopping ends the call, which keeps what it had.
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
    expect(engine.grpcStopped, [callId]);
    updates.add(
      const GrpcUpdate(
        reply: GrpcReply(
          code: 1,
          status: 'CANCELLED',
          message: 'stopped before the call ended',
          messages: ['{"n": 1}', '{"n": 2}'],
          headers: [],
          trailers: [],
          elapsedMs: 30,
        ),
      ),
    );
    await updates.close();
    await tester.pumpAndSettle();
    expect(find.text('1 CANCELLED'), findsOneWidget);
    expect(find.text('Messages (2)'), findsOneWidget);
    expect(find.text('Invoke'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains a gRPC server that cannot be reached', (tester) async {
    await open(tester);
    engine.grpcFailure = 'could not connect to localhost:1';
    await choose(tester, 'GRPC');
    await enterUrl(tester, 'localhost:1');
    await tapSend(tester);
    expect(find.byKey(const Key('grpc-error')), findsOneWidget);
    expect(find.textContaining('could not connect'), findsOneWidget);
    expect(engine.grpcCalls, isEmpty);
  });

  testWidgets('offers the authorization types the engine describes', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('auth-tab')));
    await tester.pumpAndSettle();
    expect(find.text('No Auth'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renames a request in place and flags unsaved edits', (
    tester,
  ) async {
    await open(tester);
    Future<void> rename(String name) async {
      await tester.longPress(find.byKey(const Key('title')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('title-field')), name);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    // A request can be named before it is saved anywhere.
    expect(find.text('Untitled request'), findsOneWidget);
    await rename('Draft');
    expect(find.text('Draft'), findsOneWidget);
    expect(find.byKey(const Key('title-field')), findsNothing);

    final ref = store.addStandaloneRequest(
      'Ping',
      const Request(
        method: 'GET',
        url: 'https://api.test/ping',
        headers: [],
        form: [],
        tests: [],
        captures: [],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ping'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unsaved')), findsNothing);

    // Renaming a saved request renames it in the workspace.
    await rename('Pong');
    expect(store.itemAt(ref)!.name, 'Pong');

    await enterUrl(tester, 'https://api.test/pong');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unsaved')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unsaved')), findsNothing);
    expect(store.itemAt(ref)!.request!.url, 'https://api.test/pong');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('switching the kind of request ends a WebSocket session', (
    tester,
  ) async {
    await open(tester);
    await choose(tester, 'WS');
    await enterUrl(tester, 'echo.test');
    await tapSend(tester);
    final socket = engine.sockets.values.single;
    expect(socket.isClosed, isFalse);
    await choose(tester, 'POST');
    expect(socket.isClosed, isTrue);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('saves the workspace through the engine', (tester) async {
    await open(tester);
    store.addStandaloneRequest(
      'Ping',
      const Request(
        method: 'GET',
        url: 'https://api.test/ping',
        headers: [],
        form: [],
        tests: [],
        captures: [],
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(engine.saved!.requests.single.name, 'Ping');
    expect(find.text('Ping'), findsOneWidget);
  });
}
