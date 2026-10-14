import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/runner/collection_run.dart';
import 'package:reqorb/runner/runner_dialog.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

class _RunEngine extends FakeEngine {
  @override
  List<List<Variable>> parseRunData({
    required String name,
    required String text,
  }) {
    if (text.isEmpty) throw 'the data file has no rows';
    return [
      for (final line in text.split('\n'))
        [Variable(key: 'who', value: line, enabled: true, secret: false)],
    ];
  }
}

void main() {
  late _RunEngine engine;
  late WorkspaceStore store;

  Request request(String method, String url) => Request(
    method: method,
    url: url,
    headers: const [],
    form: const [],
    tests: const [],
    captures: const [],
  );

  Item leaf(String name, String method, String url) =>
      Item(name: name, request: request(method, url), items: const []);

  /// The app with a collection: Login, a folder of two, and a WebSocket.
  Future<void> open(WidgetTester tester) async {
    engine = _RunEngine();
    store = WorkspaceStore('unused.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    store.merge(
      ImportResult(
        source: 'test',
        collections: [
          Collection(
            untrustedScripts: false,
            name: 'Shop',
            variables: const [
              Variable(key: 'base', value: 'c', enabled: true, secret: false),
            ],
            items: [
              leaf('Login', 'POST', 'https://api.test/login'),
              Item(
                name: 'Orders',
                items: [
                  leaf('List', 'GET', 'https://api.test/orders'),
                  leaf('Missing', 'GET', 'https://api.test/nope'),
                ],
              ),
              leaf('Feed', 'WS', 'wss://api.test/feed'),
            ],
          ),
        ],
        environments: const [],
        warnings: const [],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> openRunner(WidgetTester tester) async {
    await tap(tester, find.byTooltip('Collection actions'));
    await tap(tester, find.byKey(const Key('run-collection')));
  }

  String summary(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('run-summary'))).data!;

  List<String> sent() => [for (final (r, _) in engine.sends) r.url];

  test('a run takes the requests of folders in order', () {
    final steps = runSteps([
      leaf('A', 'GET', 'a'),
      Item(
        name: 'F',
        items: [
          leaf('B', 'GET', 'b'),
          Item(name: 'G', items: [leaf('C', 'GET', 'c')]),
        ],
      ),
    ], 2);
    expect([for (final s in steps) s.path], ['A', 'F/B', 'F/G/C']);
    expect(steps.every((s) => s.collection == 2), isTrue);
  });

  testWidgets('runs a collection and reports what failed', (tester) async {
    await open(tester);
    engine.onSend = (r) async => r.url.endsWith('/login')
        ? sentWith(
            response(),
            tests: const [
              TestResult(test: 'status == 200', passed: true, detail: ''),
            ],
            captured: const [
              Variable(
                key: 'token',
                value: 't-1',
                enabled: true,
                secret: false,
              ),
            ],
          )
        : sentWith(response(status: r.url.endsWith('/nope') ? 404 : 200));
    await openRunner(tester);

    // The WebSocket request is listed but cannot be chosen.
    expect(find.text('Run 3 requests'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('run-step-3')))
          .onChanged,
      isNull,
    );

    await tap(tester, find.byKey(const Key('run-start')));
    expect(sent(), [
      'https://api.test/login',
      'https://api.test/orders',
      'https://api.test/nope',
    ]);
    expect(summary(tester), startsWith('3 run · 1 failed · 1 tests, 0 failed'));
    expect(find.text('1/1 tests'), findsOneWidget);
    expect(find.text('404 Not Found'), findsOneWidget);

    // What Login captured reaches the requests after it, ahead of the
    // collection's own variables.
    final later = engine.sends[1].$2;
    expect(later.first.key, 'token');
    expect(later.last.key, 'base');
    expect(store.captured.single.value, 't-1');
  });

  testWidgets('runs only what is ticked, and a folder by itself', (
    tester,
  ) async {
    await open(tester);
    await openRunner(tester);
    await tap(tester, find.byKey(const Key('run-step-0')));
    await tap(tester, find.byKey(const Key('run-step-2')));
    expect(find.text('Run 1 request'), findsOneWidget);
    await tap(tester, find.byKey(const Key('run-start')));
    expect(sent(), ['https://api.test/orders']);
    await tap(tester, find.byKey(const Key('run-close')));

    engine.sends.clear();
    await tap(tester, find.byKey(const Key('run-folder-1')));
    expect(find.text('Run Orders'), findsOneWidget);
    await tap(tester, find.byKey(const Key('run-start')));
    expect(sent(), ['https://api.test/orders', 'https://api.test/nope']);
  });

  testWidgets('stops at the first failure when asked to', (tester) async {
    await open(tester);
    engine.onSend = (r) async => r.url.endsWith('/orders')
        ? throw 'could not connect'
        : sentWith(response());
    await openRunner(tester);
    await tap(tester, find.byKey(const Key('run-bail')));
    await tester.enterText(find.byKey(const Key('run-iterations')), '2');
    await tap(tester, find.byKey(const Key('run-start')));
    expect(sent().length, 2);
    expect(summary(tester), contains('2 run · 1 failed'));
    expect(summary(tester), endsWith('Stopped at the first failure'));
    expect(find.text('could not connect'), findsOneWidget);

    // Without it every iteration is gone through.
    engine.sends.clear();
    await tap(tester, find.byKey(const Key('run-bail')));
    await tap(tester, find.byKey(const Key('run-start')));
    expect(sent().length, 6);
    expect(find.text('Iteration 2'), findsOneWidget);
  });

  testWidgets('can be stopped while a request is on its way', (tester) async {
    await open(tester);
    final gate = Completer<Sent>();
    engine.onSend = (_) => gate.future;
    await openRunner(tester);
    await tester.tap(find.byKey(const Key('run-start')));
    await tester.pump();
    expect(summary(tester), startsWith('0 of 3'));
    await tester.tap(find.byKey(const Key('run-stop')));
    await tester.pump();
    expect(find.text('Stopping…'), findsOneWidget);
    gate.complete(sentWith(response()));
    await tester.pumpAndSettle();
    expect(sent().length, 1);
    expect(summary(tester), endsWith('Stopped'));
    expect(find.text('Run again'), findsOneWidget);
  });

  testWidgets('goes through the requests once for each row of a data file', (
    tester,
  ) async {
    await open(tester);
    var file = (name: 'who.csv', text: '');
    await tester.pumpWidget(
      EngineScope(
        engine: engine,
        child: MaterialApp(
          home: Scaffold(
            body: RunnerDialog(
              store: store,
              name: 'Shop',
              steps: runSteps(store.collections.single.items, 0),
              pickData: () async => file,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tap(tester, find.byKey(const Key('run-data')));
    expect(find.byKey(const Key('run-data-error')), findsOneWidget);

    file = (name: 'who.csv', text: 'ada\nbob\ncy');
    await tap(tester, find.byKey(const Key('run-data')));
    expect(find.byKey(const Key('run-data-error')), findsNothing);
    expect(find.text('who.csv · 3 rows'), findsOneWidget);
    expect(find.textContaining('{{who}}'), findsOneWidget);

    // Fewer iterations than rows uses only the first of them.
    await tester.enterText(find.byKey(const Key('run-iterations')), '2');
    await tap(tester, find.byKey(const Key('run-start')));
    expect(engine.sends.length, 6);
    expect(
      [for (final (_, variables) in engine.sends) variables.first.value],
      ['ada', 'ada', 'ada', 'bob', 'bob', 'bob'],
    );
  });
}
