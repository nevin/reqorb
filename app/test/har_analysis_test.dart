import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/har/har_analysis.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/shared/theme.dart';

HarEntry _entry(
  String method,
  String url,
  int status, {
  int timeMs = 100,
  int sizeBytes = 10,
  String kind = 'json',
}) => HarEntry(
  offsetMs: 0,
  method: method,
  url: url,
  host: Uri.parse(url).host,
  status: status,
  kind: kind,
  sizeBytes: sizeBytes,
  timeMs: timeMs,
  waitMs: null,
  statusText: status == 404 ? 'Not Found' : 'OK',
  requestHeaders: const [Header(name: 'accept', value: '*/*')],
  responseHeaders: const [Header(name: 'x-served-by', value: 'edge-1')],
  requestBody: null,
  responseBody: status == 404 ? null : '{"ok":true}',
  bodyNote: null,
  phases: const [
    HarPhase(name: 'dns', ms: 20),
    HarPhase(name: 'wait', ms: 80),
  ],
);

final _entries = [
  _entry('GET', 'https://api.test/items', 200, timeMs: 300),
  _entry('GET', 'https://api.test/missing', 404, timeMs: 50),
  _entry('GET', 'https://cdn.test/app.js', 200, timeMs: 900, kind: 'script'),
];

final _report = HarReport(
  creator: 'test 1.0',
  entries: _entries,
  failed: 1,
  totalBytes: 30,
  totalTimeMs: 1250,
  spanMs: 1250,
  hosts: const [
    HarCount(name: 'api.test', count: 2, bytes: 20, timeMs: 350),
    HarCount(name: 'cdn.test', count: 1, bytes: 10, timeMs: 900),
  ],
  statuses: const [
    HarCount(name: '2xx', count: 2, bytes: 20, timeMs: 1200),
    HarCount(name: '4xx', count: 1, bytes: 10, timeMs: 50),
  ],
  kinds: const [HarCount(name: 'json', count: 2, bytes: 20, timeMs: 350)],
  findings: [
    HarFinding(
      severity: HarSeverity.error,
      title: '1 client error',
      detail: 'The server rejected these requests.\n404 GET /missing',
      entries: Uint32List.fromList([1]),
    ),
  ],
);

void main() {
  late List<int>? imported;

  Future<void> open(WidgetTester tester, {Size size = const Size(1200, 1400)}) {
    imported = null;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: HarAnalysisPage(
          name: 'session.har',
          report: _report,
          onImport: (_, entries) async => imported = entries,
        ),
      ),
    );
  }

  bool shows(int index) =>
      find.byKey(Key('har-entry-$index')).evaluate().isNotEmpty;

  testWidgets('summarises the archive and lists every request', (tester) async {
    await open(tester);
    expect(find.text('HAR analysis · session.har'), findsOneWidget);
    expect(find.text('1.25 s'), findsNWidgets(2));
    expect(find.text('1 client error'), findsOneWidget);
    expect([shows(0), shows(1), shows(2)], [true, true, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrows the table by finding and by text', (tester) async {
    await open(tester);
    await tester.tap(find.text('1 client error'));
    await tester.pumpAndSettle();
    expect([shows(0), shows(1), shows(2)], [false, true, false]);
    expect(find.text('1 of 3 · 1 client error'), findsOneWidget);

    await tester.tap(find.byTooltip('Show all requests'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('har-search')), 'script');
    await tester.pumpAndSettle();
    expect([shows(0), shows(1), shows(2)], [false, false, true]);
    // Every word must match, in any of method, address, status or kind.
    await tester.enterText(find.byKey(const Key('har-search')), 'api 200');
    await tester.pumpAndSettle();
    expect([shows(0), shows(1), shows(2)], [true, false, false]);
  });

  testWidgets('sorts by time', (tester) async {
    await open(tester);
    double top(int index) =>
        tester.getTopLeft(find.byKey(Key('har-entry-$index'))).dy;
    expect(top(0) < top(1) && top(1) < top(2), isTrue);
    await tester.tap(find.byKey(const Key('har-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Slowest first').last);
    await tester.pumpAndSettle();
    expect(top(2) < top(0) && top(0) < top(1), isTrue);
  });

  testWidgets('imports only the ticked requests', (tester) async {
    await open(tester);
    expect(find.text('Import as collection'), findsOneWidget);
    await tester.tap(find.byKey(const Key('har-check-1')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 selected to import'), findsOneWidget);
    await tester.tap(find.text('Import 2 as collection'));
    expect(imported, [0, 2]);

    // The heading's box ticks or clears whatever is listed.
    await tester.enterText(find.byKey(const Key('har-search')), 'cdn');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('har-select-shown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 1 as collection'));
    expect(imported, [0]);
  });

  testWidgets('opens a request in full', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('har-entry-1')));
    await tester.pumpAndSettle();
    expect(find.text('https://api.test/missing'), findsOneWidget);
    expect(find.textContaining('404 Not Found'), findsOneWidget);
    expect(find.text('dns'), findsOneWidget);
    await tester.tap(find.byKey(const Key('har-detail-response')));
    await tester.pumpAndSettle();
    expect(find.textContaining('x-served-by'), findsOneWidget);
    expect(find.text('The archive holds no response body.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('har-detail-close')));
    await tester.pumpAndSettle();
    expect(find.text('https://api.test/missing'), findsNothing);
  });

  testWidgets('fits a narrow window without overflowing', (tester) async {
    await open(tester, size: const Size(420, 900));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
