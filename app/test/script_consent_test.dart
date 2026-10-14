import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late WorkspaceStore store;

  /// The app with a collection imported from elsewhere, whose one request
  /// has a script that has not been allowed.
  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
    store = WorkspaceStore('unused.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    store.merge(
      const ImportResult(
        source: 'postman',
        collections: [
          Collection(
            name: 'Shared',
            variables: [],
            untrustedScripts: true,
            items: [
              Item(
                name: 'Steal',
                items: [],
                request: Request(
                  method: 'GET',
                  url: 'https://api.test/x',
                  headers: [],
                  form: [],
                  tests: [],
                  captures: [],
                  preScript: "request.url += vars.get('token');",
                ),
              ),
            ],
          ),
        ],
        environments: [],
        warnings: [],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Steal'));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('scripts from elsewhere are shown and asked about', (
    tester,
  ) async {
    await open(tester);
    await send(tester);
    expect(find.byKey(const Key('script-consent')), findsOneWidget);
    // The script itself is there to be read.
    expect(find.textContaining("vars.get('token')"), findsOneWidget);

    // Cancelling sends nothing.
    await choose(tester, 'scripts-cancel');
    expect(engine.sends, isEmpty);

    // Sending without them leaves them out, and asks again next time.
    await send(tester);
    await choose(tester, 'scripts-skip');
    expect(engine.sends.single.$1.preScript, isNull);
    expect(store.collections.single.untrustedScripts, isTrue);

    // Allowed, they run, and are not asked about again.
    await send(tester);
    await choose(tester, 'scripts-allow');
    expect(engine.sends.last.$1.preScript, contains('vars.get'));
    expect(store.collections.single.untrustedScripts, isFalse);
    await send(tester);
    expect(find.byKey(const Key('script-consent')), findsNothing);
    expect(engine.sends, hasLength(3));
  });

  testWidgets('a run asks once, before it starts', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Collection actions'));
    await tester.pumpAndSettle();
    await choose(tester, 'run-collection');
    expect(find.byKey(const Key('script-consent')), findsOneWidget);
    await choose(tester, 'scripts-cancel');
    expect(find.byKey(const Key('run-start')), findsNothing);

    await tester.tap(find.byTooltip('Collection actions'));
    await tester.pumpAndSettle();
    await choose(tester, 'run-collection');
    await choose(tester, 'scripts-skip');
    await choose(tester, 'run-start');
    expect(engine.sends.single.$1.preScript, isNull);
  });
}
