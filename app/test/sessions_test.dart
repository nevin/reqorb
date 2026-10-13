import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/protocols/grpc_session.dart';
import 'package:reqorb/protocols/ws_session.dart';
import 'package:reqorb/request/send_session.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

Request _request(String url, {String method = 'GET'}) => Request(
  method: method,
  url: url,
  headers: const [Header(name: 'X-Room', value: 'blue')],
  form: const [],
  tests: const [],
  captures: const [],
);

void main() {
  group('SendSession', () {
    late FakeEngine engine;
    late WorkspaceStore store;
    late SendSession session;

    setUp(() {
      engine = FakeEngine();
      store = WorkspaceStore('unused.json', engine: engine);
      session = SendSession(engine, store);
      addTearDown(session.dispose);
    });

    test('sends, adding a scheme, and keeps the response', () async {
      var changes = 0;
      session.addListener(() => changes++);
      final sending = session.send(_request('api.test/items'), const []);
      expect(session.sending, isTrue);
      await sending;

      expect(engine.sends.single.$1.url, 'http://api.test/items');
      expect(session.sending, isFalse);
      expect(session.sent!.response.status, 200);
      expect(session.error, isNull);
      expect(changes, 2);
    });

    test('a variable in front is taken to hold the scheme', () async {
      await session.send(_request('{{base}}/items'), const []);
      expect(engine.sends.single.$1.url, '{{base}}/items');
    });

    test('reports a failure and drops the stale response', () async {
      await session.send(_request('https://api.test'), const []);
      engine.onSend = (_) async => throw 'could not connect';
      await session.send(_request('https://api.test'), const []);
      expect(session.sent, isNull);
      expect(session.error, 'could not connect');
      expect(session.sending, isFalse);
    });

    test('a cancelled send is ignored, but what it captured is kept', () async {
      final answer = Completer<Sent>();
      engine.onSend = (_) => answer.future;
      final sending = session.send(_request('https://api.test'), const []);
      session.cancel();
      expect(session.sending, isFalse);

      answer.complete(
        sentWith(
          response(),
          captured: const [
            Variable(key: 'token', value: 't', enabled: true, secret: false),
          ],
        ),
      );
      await sending;
      expect(session.sent, isNull);
      expect(store.captured.single.key, 'token');
    });

    test('opening another request abandons the send in flight', () async {
      final answer = Completer<Sent>();
      engine.onSend = (_) => answer.future;
      final sending = session.send(_request('https://api.test'), const []);
      session.reset();
      answer.complete(sentWith(response()));
      await sending;
      expect((session.sent, session.sending), (null, false));
    });

    test('does not start a second send while one is in flight', () async {
      final answer = Completer<Sent>();
      engine.onSend = (_) => answer.future;
      final first = session.send(_request('https://api.test/1'), const []);
      await session.send(_request('https://api.test/2'), const []);
      expect(engine.sends.length, 1);
      answer.complete(sentWith(response()));
      await first;
    });
  });

  group('WsSession', () {
    late FakeEngine engine;
    late WsSession session;

    setUp(() {
      engine = FakeEngine();
      session = WsSession(engine);
      addTearDown(session.dispose);
    });

    test('connects, talks and disconnects', () async {
      session.connect(_request('echo.test/ws', method: 'WS'), const []);
      expect(session.connecting, isTrue);
      await pumpEventQueue();
      expect((session.open, session.connecting), (true, false));
      final opened = engine.socketRequests.values.single;
      expect((opened.url, opened.method), ('ws://echo.test/ws', 'GET'));
      expect(opened.headers.single.value, 'blue');

      session.send('hello');
      session.send('');
      engine.sockets.values.single.add(wsEvent(WsEventKind.text, 'HELLO'));
      await pumpEventQueue();
      expect(engine.wsSent, ['hello']);
      expect(
        [for (final e in session.log) '${e.sent ? '>' : '<'} ${e.text}'],
        ['< Connected · 101 Switching Protocols', '> hello', '< HELLO'],
      );

      session.disconnect();
      await pumpEventQueue();
      expect(session.open, isFalse);
      expect(session.log.last.text, startsWith('Disconnected'));
      // Nothing is sent once the connection has gone.
      session.send('late');
      expect(engine.wsSent, ['hello']);
    });

    test('gives up on a connection that never opened', () async {
      engine.wsAccepts = false;
      session.connect(_request('wss://slow.test'), const []);
      await pumpEventQueue();
      expect((session.open, session.connecting), (false, true));
      session.disconnect();
      expect(session.connecting, isFalse);
    });

    test('resetting drops the connection and the log', () async {
      session.connect(_request('ws://echo.test'), const []);
      await pumpEventQueue();
      final socket = engine.sockets.values.single;
      session.reset();
      expect(session.open, isFalse);
      expect(session.log, isEmpty);
      expect(socket.isClosed, isTrue);
    });
  });

  group('GrpcSession', () {
    late FakeEngine engine;
    late GrpcSession session;

    setUp(() {
      engine = FakeEngine();
      session = GrpcSession(engine);
      addTearDown(session.dispose);
    });

    test('loads the methods by reflection or from a file', () async {
      final request = _request('localhost:50051', method: 'GRPC');
      final loading = session.load(request: request, variables: const []);
      expect(session.busy, isTrue);
      expect((await loading)!.methods.length, 2);
      expect((session.busy, engine.reflections), (false, 1));

      await session.load(
        proto: '/tmp/shop.proto',
        request: request,
        variables: const [],
      );
      expect(engine.protoPaths, ['/tmp/shop.proto']);
      expect(engine.reflections, 1);
    });

    test('calls a method and keeps the reply', () async {
      final request = _request('localhost:50051', method: 'GRPC');
      // Nothing can be called before the methods are known.
      await session.call(
        request: request,
        method: 'shop.Orders/Get',
        messages: const ['{"id":1}'],
        variables: const [],
      );
      expect(engine.grpcCalls, isEmpty);

      await session.load(request: request, variables: const []);
      await session.call(
        request: request,
        method: 'shop.Orders/Get',
        messages: const ['{"id":1}'],
        variables: const [],
      );
      final call = engine.grpcCalls.single;
      expect((call.url, call.method), ('localhost:50051', 'shop.Orders/Get'));
      expect(call.messages, ['{"id":1}']);
      expect(session.reply!.messages.single, contains('9.5'));
      expect((session.busy, session.error), (false, null));
    });

    test('reports failures', () async {
      engine.grpcFailure = 'could not connect';
      final request = _request('localhost:1', method: 'GRPC');
      expect(await session.load(request: request, variables: const []), isNull);
      expect((session.error, session.busy), ('could not connect', false));
    });

    test('work for one request does not report into the next', () async {
      final request = _request('localhost:50051', method: 'GRPC');
      final loading = session.load(request: request, variables: const []);
      session.reset();
      expect(await loading, isNull);
      expect((session.schema, session.busy), (null, false));
    });
  });
}
