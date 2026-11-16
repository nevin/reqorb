import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/protocols/ws_session.dart';
import 'package:reqorb/protocols/ws_view.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';

import 'fake_engine.dart';

void main() {
  final entries = [
    WsEntry.received(wsEvent(WsEventKind.open, 'Switching Protocols')),
    WsEntry.sent('{"op":"subscribe","to":"prices"}'),
    WsEntry.received(wsEvent(WsEventKind.text, 'subscribed')),
    WsEntry.received(
      WsEvent(
        kind: WsEventKind.binary,
        text: '',
        data: Uint8List.fromList([0, 1, 254, 255]),
        code: 0,
        headers: const [],
        atMs: 0,
      ),
    ),
    WsEntry.received(wsEvent(WsEventKind.pong)),
  ];
  var saved = 0;
  var analysed = 0;

  Future<void> open(WidgetTester tester, [List<WsEntry>? log]) {
    tester.view.physicalSize = const Size(520, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: WsLogView(
            entries: log ?? entries,
            connected: true,
            connecting: false,
            onClear: () {},
            onSave: () => saved++,
            onAnalyse: () => analysed++,
          ),
        ),
      ),
    );
  }

  testWidgets('filters the log by text and by direction', (tester) async {
    await open(tester);
    expect(find.text('3 messages'), findsOneWidget);
    expect(find.byKey(const Key('ws-filter')), findsNothing);

    await tester.tap(find.byKey(const Key('ws-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ws-filter')), 'SUBSCRIBE');
    await tester.pumpAndSettle();
    expect(find.text('subscribed'), findsOneWidget);
    expect(find.text('pong'), findsNothing);
    expect(find.text('2 of 5'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ws-show')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sent').last);
    await tester.pumpAndSettle();
    expect(find.text('subscribed'), findsNothing);
    expect(find.textContaining('"op"'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('ws-filter')), 'nothing');
    await tester.pumpAndSettle();
    expect(find.text('No line matches the filter'), findsOneWidget);

    // Hiding the filter shows every line again.
    await tester.tap(find.byKey(const Key('ws-search')));
    await tester.pumpAndSettle();
    expect(find.text('pong'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a line to show all of it, and copies it', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    await open(tester);
    // JSON and binary data have more to show; a plain line has not.
    expect(find.byTooltip('Show all of it'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Show all of it').first);
    await tester.pumpAndSettle();
    const indented = '{\n  "op": "subscribe",\n  "to": "prices"\n}';
    expect(find.text(indented), findsOneWidget);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    expect(copied, indented);

    await tester.tap(find.byTooltip('Show less'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show all of it').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('00 01 fe ff'), findsOneWidget);
  });

  testWidgets('offers to save and to analyse what there is', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('ws-save')));
    await tester.tap(find.byKey(const Key('ws-analyse')));
    expect((saved, analysed), (1, 1));

    await open(tester, const []);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ws-save')));
    await tester.tap(find.byKey(const Key('ws-analyse')));
    expect((saved, analysed), (1, 1));
  });

  test('a session writes its log out as HAR', () async {
    final engine = FakeEngine();
    final session = WsSession(engine);
    addTearDown(session.dispose);
    expect(session.har(redact: false), isNull);

    session.connect(
      const Request(
        method: 'WS',
        url: 'echo.test/ws',
        headers: [],
        form: [],
        tests: [],
        captures: [],
      ),
      const [],
    );
    await pumpEventQueue();
    session.send('hello');
    expect(session.har(redact: true), isNotNull);

    final (request, lines, redact) = engine.wsLogs.single;
    expect((request.url, redact), ('ws://echo.test/ws', true));
    expect(
      [for (final line in lines) (line.sent, line.event.kind, line.event.text)],
      [
        (false, WsEventKind.open, 'Switching Protocols'),
        (true, WsEventKind.text, 'hello'),
      ],
    );
  });
}
