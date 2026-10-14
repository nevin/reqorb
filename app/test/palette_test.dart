import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/palette/command_palette.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late WorkspaceStore store;

  Item leaf(String name, String method, String url) => Item(
    name: name,
    request: Request(
      method: method,
      url: url,
      headers: const [],
      form: const [],
      tests: const [],
      captures: const [],
    ),
    items: const [],
  );

  /// The app with a collection, a standalone request and an environment.
  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
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
            variables: const [],
            items: [
              leaf('Login', 'POST', 'https://api.test/login'),
              Item(
                name: 'Orders',
                items: [
                  leaf('List orders', 'GET', 'https://api.test/orders'),
                  leaf('Create order', 'POST', 'https://api.test/orders'),
                ],
              ),
            ],
          ),
        ],
        environments: const [Environment(name: 'Staging', variables: [])],
        warnings: const [],
      ),
    );
    store.addStandaloneRequest(
      'Ping',
      leaf('Ping', 'GET', 'https://api.test/ping').request!,
    );
    await tester.pumpAndSettle();
  }

  Future<void> palette(WidgetTester tester, String query) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('palette-input')), query);
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  String url(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const Key('url'))).controller!.text;

  PaletteItem item(String title, [String detail = '']) =>
      PaletteItem(title: title, detail: detail, kind: 'Request', run: () {});

  test('a query matches letters in order and prefers the starts of words', () {
    expect(paletteScore('xyz', 'List orders'), isNull);
    expect(paletteScore('lo', 'List orders'), isNotNull);
    expect(
      paletteScore('lo', 'List orders')!,
      greaterThan(paletteScore('lo', 'Flood')!),
    );
    final found = paletteMatches('ord', [
      item('Login', 'Shop / Orders'),
      item('Reorder'),
      item('Orders'),
      item('Ping'),
    ]);
    // The name that starts with it, then one holding it, then the folder.
    expect([for (final f in found) f.title], ['Orders', 'Reorder', 'Login']);
    expect(paletteMatches('  ', [item('A'), item('B')]).length, 2);
  });

  testWidgets('finds a saved request by a few letters and opens it', (
    tester,
  ) async {
    await open(tester);
    await palette(tester, 'crord');
    expect(find.text('Shop / Orders'), findsOneWidget);
    await enter(tester);
    expect(find.byKey(const Key('palette-input')), findsNothing);
    expect(url(tester), 'https://api.test/orders');

    // The arrows move through what was found: down to the request that
    // is already open, which opens nothing new.
    await palette(tester, 'ord');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await enter(tester);
    expect(find.byKey(const Key('tab-1')), findsNothing);
    await palette(tester, 'ord');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await enter(tester);
    expect(find.byKey(const Key('tab-1')), findsOneWidget);
  });

  testWidgets('switches tab and environment, and runs actions', (tester) async {
    await open(tester);
    await palette(tester, 'ping');
    await enter(tester);
    await palette(tester, 'login');
    await enter(tester);
    expect(url(tester), 'https://api.test/login');

    // The other open request is offered as a tab, ahead of the saved one.
    await palette(tester, 'ping');
    expect(find.text('Open tab'), findsOneWidget);
    await enter(tester);
    expect(url(tester), 'https://api.test/ping');
    expect(find.byKey(const Key('tab-2')), findsNothing);

    await palette(tester, 'staging');
    await enter(tester);
    expect(store.activeEnvironment, 'Staging');
    await palette(tester, 'no env');
    await enter(tester);
    expect(store.activeEnvironment, isNull);

    await palette(tester, 'run shop');
    await enter(tester);
    expect(find.text('Run 3 requests'), findsOneWidget);
    await tester.tap(find.byKey(const Key('run-close')));
    await tester.pumpAndSettle();

    await palette(tester, 'new req');
    await enter(tester);
    expect(url(tester), '');
  });

  testWidgets('opens from its button and says when nothing matches', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('palette')));
    await tester.pumpAndSettle();
    expect(find.text('Send the request'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('palette-input')), 'qqqq');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches'), findsOneWidget);
    await enter(tester);
    expect(find.byKey(const Key('palette-input')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('palette-input')), findsNothing);
  });
}
