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
            unreviewed: true,
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
    expect(find.byKey(const Key('collection-review')), findsOneWidget);
    // The script itself is there to be read.
    expect(find.textContaining("vars.get('token')"), findsOneWidget);

    // Cancelling sends nothing.
    await choose(tester, 'review-cancel');
    expect(engine.sends, isEmpty);

    // Sending without them leaves them out, and asks again next time.
    await send(tester);
    await choose(tester, 'review-skip');
    expect(engine.sends.single.$1.preScript, isNull);
    expect(store.collections.single.unreviewed, isTrue);

    // Allowed, they run, and are not asked about again.
    await send(tester);
    await choose(tester, 'review-allow');
    expect(engine.sends.last.$1.preScript, contains('vars.get'));
    expect(store.collections.single.unreviewed, isFalse);
    await send(tester);
    expect(find.byKey(const Key('collection-review')), findsNothing);
    expect(engine.sends, hasLength(3));
  });

  testWidgets('a run asks once, before it starts', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Collection actions'));
    await tester.pumpAndSettle();
    await choose(tester, 'run-collection');
    expect(find.byKey(const Key('collection-review')), findsOneWidget);
    await choose(tester, 'review-cancel');
    expect(find.byKey(const Key('run-start')), findsNothing);

    await tester.tap(find.byTooltip('Collection actions'));
    await tester.pumpAndSettle();
    await choose(tester, 'run-collection');
    await choose(tester, 'review-skip');
    await choose(tester, 'run-start');
    expect(engine.sends.single.$1.preScript, isNull);
  });

  testWidgets('files a collection reads are shown, and must be allowed', (
    tester,
  ) async {
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
            unreviewed: true,
            items: [
              Item(
                name: 'Upload',
                items: [],
                request: Request(
                  method: 'POST',
                  url: 'https://api.test/x',
                  headers: [],
                  bodyMode: BodyMode.binary,
                  body: '/Users/me/.ssh/id_rsa',
                  form: [],
                  tests: [],
                  captures: [],
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
    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    await send(tester);
    expect(find.textContaining('/Users/me/.ssh/id_rsa'), findsOneWidget);
    // Leaving scripts out would not stop the file being read.
    expect(find.byKey(const Key('review-skip')), findsNothing);
    await choose(tester, 'review-cancel');
    expect(engine.sends, isEmpty);
    await send(tester);
    await choose(tester, 'review-allow');
    expect(engine.sends, hasLength(1));
    expect(store.collections.single.unreviewed, isFalse);
  });
}
