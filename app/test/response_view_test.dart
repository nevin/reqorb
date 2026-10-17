import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/editor/document_view.dart';
import 'package:reqorb/response/response_view.dart';
import 'package:reqorb/src/rust/api/core.dart';

import 'fake_engine.dart';

void main() {
  /// The response pane showing a response with these headers and body.
  Future<void> show(
    WidgetTester tester, {
    required List<Header> headers,
    required String body,
  }) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sent = sentWith(
      Response(
        status: 200,
        statusText: 'OK',
        httpVersion: 'HTTP/1.1',
        headers: headers,
        body: body,
        sizeBytes: body.length,
        elapsedMs: 12,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResponseView(
            sent: sent,
            error: null,
            errorTitle: '',
            sending: false,
            sessionSize: 1,
            onExportSession: () {},
          ),
        ),
      ),
    );
  }

  String shown(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('responseBody')))
      .controller!
      .text;

  /// What the copy button puts on the clipboard.
  Future<String?> copy(WidgetTester tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const Key('copy-response')));
    await tester.pumpAndSettle();
    return copied;
  }

  testWidgets('a JSON body is shown pretty or as received', (tester) async {
    // Labelled as text, but JSON all the same.
    await show(
      tester,
      headers: const [Header(name: 'content-type', value: 'text/plain')],
      body: '{"a":1}',
    );
    expect(shown(tester), contains('\n'));

    await tester.tap(find.byKey(const Key('body-raw')));
    await tester.pumpAndSettle();
    expect(shown(tester), '{"a":1}');
    expect(await copy(tester), '{"a":1}');

    await tester.tap(find.byKey(const Key('body-pretty')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text').last);
    await tester.pumpAndSettle();
    expect(shown(tester), '{"a":1}');
  });

  testWidgets('a body too long for an editor is shown a line at a time', (
    tester,
  ) async {
    // Minified, as big responses often are: one line of over a megabyte.
    final items = [
      for (var i = 0; i < 40000; i++) '{"id":$i,"name":"item $i"}',
    ];
    final body = '[${items.join(',')}]';
    expect(body.length, greaterThan(editLimit));
    await show(
      tester,
      headers: const [Header(name: 'content-type', value: 'application/json')],
      body: body,
    );
    String text() =>
        tester.widget<DocumentText>(find.byType(DocumentText)).text;

    // As received while it is re-indented apart; the one line goes on
    // over rows that are not numbered.
    expect(find.byKey(const Key('responseBody')), findsNothing);
    expect(text(), body);
    String number(int row) => tester
        .widget<Text>(find.byKey(ValueKey('responseBody-document-number-$row')))
        .data!;
    expect([number(0), number(1), number(2)], ['1', '', '']);

    // Then re-indented, once.
    for (var i = 0; i < 100 && !text().contains('\n'); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(text(), startsWith('[\n'));
    expect(text(), contains('"name": "item 39999"'));
  });

  testWidgets('the search button opens the find bar', (tester) async {
    await show(
      tester,
      headers: const [Header(name: 'content-type', value: 'application/json')],
      body: '{"a":1}',
    );
    expect(find.byKey(const Key('responseBody-find-field')), findsNothing);
    await tester.tap(find.byKey(const Key('responseBody-find')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('responseBody-find-field')), findsOneWidget);
  });

  testWidgets('the cookies the response set have a tab', (tester) async {
    await show(
      tester,
      headers: const [
        Header(name: 'Set-Cookie', value: 'sid=abc; Path=/; HttpOnly'),
        Header(name: 'set-cookie', value: 'theme=dark'),
      ],
      body: 'ok',
    );
    await tester.tap(find.byKey(const Key('cookies-tab')));
    await tester.pumpAndSettle();
    expect(find.text('Cookies (2)'), findsOneWidget);
    expect(find.text('sid'), findsOneWidget);
    expect(find.text('Path=/ · HttpOnly'), findsOneWidget);
    expect(find.text('theme'), findsOneWidget);
    expect(await copy(tester), 'sid=abc; Path=/; HttpOnly\ntheme=dark');
  });

  testWidgets('copy takes the tab showing, events or not', (tester) async {
    await show(
      tester,
      headers: const [Header(name: 'content-type', value: 'text/event-stream')],
      body: 'data: hi\n\n',
    );
    await tester.tap(find.text('Body'));
    await tester.pumpAndSettle();
    expect(await copy(tester), 'data: hi\n\n');
    await tester.tap(find.textContaining('Headers'));
    await tester.pumpAndSettle();
    expect(await copy(tester), 'content-type: text/event-stream');
  });

  test('a Set-Cookie value is split into the cookie and its attributes', () {
    final cookie = parseSetCookie('a=b=c; Secure;  SameSite=Lax ');
    expect(cookie.name, 'a');
    expect(cookie.value, 'b=c');
    expect(cookie.attributes, ['Secure', 'SameSite=Lax']);
  });

  testWidgets('Preview is offered only where pages can be shown', (
    tester,
  ) async {
    // Tests run without a web view, as Windows and Linux do.
    await show(
      tester,
      headers: const [Header(name: 'content-type', value: 'text/html')],
      body: '<html><body>hi</body></html>',
    );
    expect(previewsHtml, isFalse);
    expect(find.byKey(const Key('body-pretty')), findsOneWidget);
    expect(find.byKey(const Key('body-preview')), findsNothing);
  });

  testWidgets('elsewhere, the page can be opened in the browser', (
    tester,
  ) async {
    await show(
      tester,
      headers: const [Header(name: 'content-type', value: 'text/html')],
      body: '<html><body>hi</body></html>',
    );
    expect(find.byKey(const Key('body-open-browser')), findsOneWidget);
  });

  testWidgets('a body that is not a page has no browser button', (
    tester,
  ) async {
    await show(
      tester,
      headers: const [Header(name: 'content-type', value: 'application/json')],
      body: '{"a":1}',
    );
    expect(find.byKey(const Key('body-open-browser')), findsNothing);
  });

  test('a page for the browser runs no scripts, and keeps its doctype', () {
    final page = pageForBrowser(
      '<!DOCTYPE html><html><script>x()</script></html>',
      'https://a.test/p?x=1&y="2"',
    );
    expect(page, startsWith('<!DOCTYPE html><meta http-equiv='));
    expect(page, contains("script-src 'none'"));
    expect(
      page,
      contains('<base href="https://a.test/p?x=1&amp;y=&quot;2&quot;">'),
    );
    expect(pageForBrowser('<p>hi</p>', null), endsWith("'none'\"><p>hi</p>"));
  });

  testWidgets('a body too big to hold is shown from its file', (tester) async {
    final dir = Directory.systemTemp.createTempSync('reqorb_spilled');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/body';
    final lines = [for (var i = 0; i < 3000; i++) '{"row": $i}'].join('\n');
    File(path).writeAsStringSync(lines);
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sent = sentWith(
      Response(
        status: 200,
        statusText: 'OK',
        httpVersion: 'HTTP/1.1',
        headers: const [
          Header(name: 'content-type', value: 'application/json'),
        ],
        // Only its start is held.
        body: lines.substring(0, 100),
        bodyFile: path,
        sizeBytes: 40 * 1024 * 1024,
        elapsedMs: 12,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResponseView(
            sent: sent,
            error: null,
            errorTitle: '',
            sending: false,
            sessionSize: 1,
            onExportSession: () {},
          ),
        ),
      ),
    );
    // Opened, and re-indented: files read and written outside the clock.
    for (var i = 0; i < 40 && find.text('  "row": 0').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.byKey(const Key('response-from-file')), findsOneWidget);
    // Pretty is the JSON re-indented, into a file of its own.
    expect(find.text('  "row": 0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('body-raw')));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.text('{"row": 0}'), findsOneWidget);
    // All of it is there, not only what was held.
    await tester.tap(find.text('{"row": 0}'));
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(find.text('{"row": 2999}'), findsOneWidget);

    // Copying takes the whole body from the file.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.tap(find.byKey(const Key('copy-response')));
    for (var i = 0; i < 10 && copied == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(copied, lines);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('JSON can be explored as a tree', (tester) async {
    await show(
      tester,
      headers: const [Header(name: 'content-type', value: 'application/json')],
      body: '{"a": [1, 2], "b": "x"}',
    );
    await tester.tap(find.byKey(const Key('body-tree')));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.textContaining('"a": […]'), findsOneWidget);
    expect(find.text('"b": "x"'), findsOneWidget);
    await tester.tap(find.textContaining('"a": […]'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.text('1: 2'), findsOneWidget);
    expect(find.textContaining('2 items'), findsOneWidget);
  });

  testWidgets('a binary body can be shown as bytes', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sent = sentWith(
      Response(
        status: 200,
        statusText: 'OK',
        httpVersion: 'HTTP/1.1',
        headers: const [
          Header(name: 'content-type', value: 'application/octet-stream'),
        ],
        body: '',
        bytes: Uint8List.fromList([0, 1, 0x41, 0xff]),
        sizeBytes: 4,
        elapsedMs: 12,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResponseView(
            sent: sent,
            error: null,
            errorTitle: '',
            sending: false,
            sessionSize: 1,
            onExportSession: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('binary-hex')));
    await tester.pump();
    expect(find.textContaining('00 01 41 ff'), findsOneWidget);
    expect(find.textContaining('..A.'), findsOneWidget);
  });
}
