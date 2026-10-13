import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/response/sse.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late WorkspaceStore store;
  late StreamController<SendUpdate> updates;
  late int sendId;

  const events = [Header(name: 'Content-Type', value: 'text/event-stream')];
  const json = [Header(name: 'content-type', value: 'application/json')];

  /// The app with a send that the test answers piece by piece.
  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
    updates = StreamController<SendUpdate>();
    engine.onWatch = (id, _) {
      sendId = id;
      return updates.stream;
    };
    store = WorkspaceStore('unused.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    await tester.enterText(
      find.byKey(const Key('url')),
      'https://api.test/events',
    );
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
  }

  /// Hands the app a piece of the response and lets it be shown.
  Future<void> push(WidgetTester tester, SendUpdate update) async {
    updates.add(update);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
  }

  String button(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const Key('send')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  test('reads the events of a stream', () {
    final found = parseSse(
      ': keep-alive\n'
      'data: one\n\n'
      'event: tick\r\nid: 7\r\ndata: {"n":\r\ndata: 2}\r\n\r\n'
      'data:three\n\n'
      'event: empty\n\n'
      'data: unfinished\n',
    );
    expect(
      [for (final e in found) '${e.event}|${e.id}|${e.data}'],
      ['message||one', 'tick|7|{"n":\n2}', 'message|7|three'],
    );
    expect(parseSse(''), isEmpty);
  });

  testWidgets('shows a stream as it arrives, and stops it', (tester) async {
    await open(tester);
    expect(button(tester), 'Cancel');

    await push(tester, sendUpdate(SendUpdateKind.head, headers: events));
    expect(button(tester), 'Stop');
    expect(find.byKey(const Key('receiving')), findsOneWidget);
    expect(find.text('Waiting for the first event…'), findsOneWidget);
    // The response is not final, so it is not marked as the answer yet.
    expect(find.byKey(const Key('status')), findsNothing);

    await push(
      tester,
      sendUpdate(SendUpdateKind.body, text: 'data: one\n\n', received: 11),
    );
    expect(find.text('Events (1)'), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
    await push(
      tester,
      sendUpdate(
        SendUpdateKind.body,
        text: 'event: tick\ndata: two\n\n',
        received: 33,
      ),
    );
    expect(find.text('Events (2)'), findsOneWidget);
    expect(find.text('tick'), findsOneWidget);

    // Stopping asks the engine to end the send, and keeps what arrived.
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
    expect(engine.stopped, [sendId]);
    await push(
      tester,
      sendUpdate(
        SendUpdateKind.done,
        sent: sentWith(
          Response(
            status: 200,
            statusText: 'OK',
            httpVersion: 'HTTP/1.1',
            headers: events,
            body: 'data: one\n\nevent: tick\ndata: two\n\n',
            sizeBytes: 33,
            elapsedMs: 40,
          ),
        ),
      ),
    );
    await updates.close();
    await tester.pumpAndSettle();
    expect(button(tester), 'Send');
    expect(find.byKey(const Key('stopped')), findsOneWidget);
    expect(find.byKey(const Key('receiving')), findsNothing);
    expect(find.byKey(const Key('status')), findsOneWidget);
    expect(find.text('Events (2)'), findsOneWidget);
  });

  testWidgets('the next send is followed just as the first was', (
    tester,
  ) async {
    await open(tester);
    // The first ends the moment after a piece of its body arrives.
    updates.add(sendUpdate(SendUpdateKind.head, headers: events));
    updates.add(
      sendUpdate(SendUpdateKind.body, text: 'data: a\n\n', received: 9),
    );
    updates.add(sendUpdate(SendUpdateKind.done, sent: sentWith(response())));
    await updates.close();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('status')), findsOneWidget);

    updates = StreamController<SendUpdate>();
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
    await push(tester, sendUpdate(SendUpdateKind.head, headers: events));
    await push(
      tester,
      sendUpdate(SendUpdateKind.body, text: 'data: b\n\n', received: 9),
    );
    expect(find.text('Events (1)'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    await push(
      tester,
      sendUpdate(SendUpdateKind.done, sent: sentWith(response())),
    );
    await updates.close();
    await tester.pumpAndSettle();
  });

  testWidgets('a large body is counted until it is whole', (tester) async {
    await open(tester);
    await push(tester, sendUpdate(SendUpdateKind.head, headers: json));
    await push(
      tester,
      sendUpdate(SendUpdateKind.body, text: '{"a":', received: 5),
    );
    expect(find.byKey(const Key('events-tab')), findsNothing);
    await push(
      tester,
      sendUpdate(SendUpdateKind.body, text: 'x' * 10, received: 400 * 1024),
    );
    expect(find.textContaining('Receiving the response…'), findsOneWidget);
    expect(find.textContaining('400'), findsWidgets);

    await push(
      tester,
      sendUpdate(SendUpdateKind.done, sent: sentWith(response())),
    );
    await updates.close();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('status')), findsOneWidget);
    expect(find.byKey(const Key('stopped')), findsNothing);
  });

  testWidgets('a send cancelled before any answer is dropped', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
    expect(engine.stopped, [sendId]);
    expect(button(tester), 'Send');
    // What comes back afterwards is not shown.
    await push(tester, sendUpdate(SendUpdateKind.failed, text: 'cancelled'));
    await updates.close();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('error')), findsNothing);
    expect(find.byKey(const Key('status')), findsNothing);
  });

  testWidgets('a failure part way is reported', (tester) async {
    await open(tester);
    await push(tester, sendUpdate(SendUpdateKind.head, headers: json));
    await push(
      tester,
      sendUpdate(SendUpdateKind.failed, text: 'connection reset'),
    );
    await updates.close();
    await tester.pumpAndSettle();
    expect(find.text('connection reset'), findsOneWidget);
    expect(button(tester), 'Send');
  });
}
