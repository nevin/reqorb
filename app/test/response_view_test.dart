import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
