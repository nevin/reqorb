import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/history/history_page.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

Request _request(String url, {String method = 'GET'}) => Request(
  method: method,
  url: url,
  headers: const [],
  form: const [],
  tests: const [],
  captures: const [],
);

Exchange _exchange(
  String url, {
  int status = 200,
  DateTime? at,
  String method = 'GET',
}) => Exchange(
  startedMs: (at ?? DateTime.now()).millisecondsSinceEpoch,
  request: _request(url, method: method),
  response: response(status: status, body: '{"from":"$url"}'),
);

void main() {
  test('requests are listed under the day they were sent', () {
    final now = DateTime(2026, 3, 10, 0, 30);
    expect(dayOf(DateTime(2026, 3, 10, 0, 5), now), 'Today');
    // Yesterday by the calendar, though less than an hour ago.
    expect(dayOf(DateTime(2026, 3, 9, 23, 55), now), 'Yesterday');
    expect(dayOf(DateTime(2026, 3, 8, 12), now), '2026-03-08');
    expect(dayOf(DateTime(2025, 12, 31), now), '2025-12-31');
  });

  group('store', () {
    late FakeEngine engine;
    late WorkspaceStore store;

    setUp(() {
      engine = FakeEngine();
      store = WorkspaceStore('/data/app/workspace.json', engine: engine);
    });

    test('keeps history beside the workspace', () {
      expect(store.historyPath, '/data/app/history.jsonl');
      expect(
        WorkspaceStore(r'C:\data\workspace.json', engine: engine).historyPath,
        r'C:\data\history.jsonl',
      );
      expect(
        WorkspaceStore('workspace.json', engine: engine).historyPath,
        'history.jsonl',
      );
    });

    test('records every exchange of a send, the last as its answer', () async {
      final source = _request('{{base}}/new');
      store.record(
        [
          _exchange('https://api.test/old', status: 404),
          _exchange('https://api.test/new'),
        ],
        source: source,
        name: 'Moved',
      );
      await store.historyWritten();
      expect(store.session, hasLength(2));
      expect(store.history, hasLength(2));
      final [redirect, answer] = engine.history;
      expect((redirect.source, redirect.name), (null, ''));
      expect((answer.source, answer.name), (source, 'Moved'));

      // The next launch finds them again.
      final next = WorkspaceStore('/data/app/workspace.json', engine: engine);
      engine.unreadableHistory = 3;
      await next.loadHistory();
      expect(next.history, hasLength(2));
      expect(next.unreadableHistory, 3);
      expect(next.session, isEmpty);
    });

    test('keeps no more than the settings allow', () async {
      store.updateSettings(store.settings.copyWith(historyLimit: 3));
      for (var n = 1; n <= 5; n++) {
        store.record([
          _exchange('https://api.test/$n'),
        ], source: _request('$n'));
      }
      expect(
        [for (final e in store.history) e.exchange.request.url],
        ['https://api.test/3', 'https://api.test/4', 'https://api.test/5'],
      );

      // Fewer are wanted: the oldest go at once.
      store.updateSettings(store.settings.copyWith(historyLimit: 1));
      expect(store.history.single.exchange.request.url, 'https://api.test/5');

      // None are wanted: what was kept is forgotten, on disk too, and
      // nothing more is recorded. The session is not history.
      store.updateSettings(store.settings.copyWith(historyLimit: 0));
      await store.historyWritten();
      expect(store.history, isEmpty);
      expect(engine.history, isEmpty);
      store.record([_exchange('https://api.test/6')], source: _request('6'));
      await store.historyWritten();
      expect(store.history, isEmpty);
      expect(engine.history, isEmpty);
      expect(store.session, hasLength(6));
    });

    test('clearing forgets what is on disk as well', () async {
      store.record([_exchange('https://api.test/1')], source: _request('1'));
      store.clearHistory();
      await store.historyWritten();
      expect(store.history, isEmpty);
      expect(engine.history, isEmpty);
    });
  });

  group('in the app', () {
    late FakeEngine engine;
    late WorkspaceStore store;

    Future<void> open(WidgetTester tester) async {
      engine = FakeEngine();
      store = WorkspaceStore('unused.json', engine: engine);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ReqorbApp(store: store));
      addTearDown(() => tester.pump(const Duration(seconds: 5)));
      // Answers as the real engine does: with the exchange that took place.
      engine.onSend = (request) async => Sent(
        response: response(
          status: request.url.contains('missing') ? 404 : 200,
          body: '{"from":"${request.url}"}',
        ),
        unresolved: const [],
        cookies: const [],
        exchanges: [
          _exchange(
            request.url.replaceAll('{{base}}', 'https://api.test'),
            status: request.url.contains('missing') ? 404 : 200,
          ),
        ],
        tests: const [],
        captured: const [],
        captureProblems: const [],
        graphqlErrors: const [],
        console: const [],
      );
    }

    Future<void> send(WidgetTester tester, String url) async {
      await tester.enterText(find.byKey(const Key('url')), url);
      await tester.tap(find.byKey(const Key('send')));
      await tester.pumpAndSettle();
    }

    Future<void> showHistoryPage(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('history')));
      await tester.pumpAndSettle();
    }

    String url(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(const Key('url'))).controller!.text;

    testWidgets('lists what was sent and opens it again with its response', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('History'), findsOneWidget);
      await send(tester, '{{base}}/users?page=2');
      await send(tester, 'https://api.test/missing');
      expect(find.text('History · 2'), findsOneWidget);

      await showHistoryPage(tester);
      expect(find.text('Today'), findsOneWidget);
      // Newest first.
      expect(
        find.descendant(
          of: find.byKey(const Key('history-row-0')),
          matching: find.text('/missing'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('history-row-1')),
          matching: find.text('/users?page=2'),
        ),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('history-search')),
        'get 200',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('history-row-1')), findsNothing);
      expect(find.text('/users?page=2'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('history-search')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No request matches'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('history-search')), 'users');
      await tester.pumpAndSettle();

      // Opened, it is the request as it was written, variables and all,
      // with the response it got, and nothing is sent to show it.
      await tester.tap(find.byKey(const Key('history-row-0')));
      await tester.pumpAndSettle();
      expect(find.byType(HistoryPage), findsNothing);
      expect(url(tester), '{{base}}/users?page=2');
      expect(find.text('200 OK'), findsOneWidget);
      expect(
        find.textContaining('From history: sent today at'),
        findsOneWidget,
      );
      expect(engine.sends, hasLength(2));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('clears history after asking', (tester) async {
      await open(tester);
      await send(tester, 'https://api.test/a');
      await showHistoryPage(tester);
      await tester.tap(find.byKey(const Key('history-clear')));
      await tester.pumpAndSettle();
      expect(find.text('Clear history?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.history, hasLength(1));

      await tester.tap(find.byKey(const Key('history-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('history-clear-confirm')));
      await tester.pumpAndSettle();
      expect(store.history, isEmpty);
      expect(
        tester.widget<Text>(find.byKey(const Key('history-empty'))).data,
        'Requests you send are listed here, with their responses.',
      );
    });

    testWidgets('says what it cannot show and when it is switched off', (
      tester,
    ) async {
      await open(tester);
      engine
        ..history = [
          HistoryEntry(
            exchange: _exchange(
              'https://api.test/old',
              at: DateTime.now().subtract(const Duration(days: 40)),
            ),
            name: 'Saved name',
            cut: false,
          ),
        ]
        ..unreadableHistory = 2;
      await store.loadHistory();
      await tester.pumpAndSettle();
      await showHistoryPage(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('history-unreadable'))).data,
        startsWith('2 earlier requests cannot be shown'),
      );
      expect(find.text('Saved name'), findsOneWidget);
      expect(find.text('Today'), findsNothing);

      // An entry with no written request is read back from what was sent.
      engine.importResult = ImportResult(
        source: 'har',
        collections: [
          Collection(
            name: 'History',
            variables: const [],
            items: [
              Item(
                name: 'GET /old',
                request: _request('https://api.test/old?rebuilt=1'),
                items: const [],
              ),
            ],
          ),
        ],
        environments: const [],
        warnings: const [],
      );
      await tester.tap(find.byKey(const Key('history-row-0')));
      await tester.pumpAndSettle();
      expect(url(tester), 'https://api.test/old?rebuilt=1');
      await tester.pump(const Duration(seconds: 5));

      store.updateSettings(store.settings.copyWith(historyLimit: 0));
      await tester.pumpAndSettle();
      await showHistoryPage(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('history-empty'))).data,
        'History is switched off in Settings.',
      );
    });
  });
}
