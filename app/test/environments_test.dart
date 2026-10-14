import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/environments/environments.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  testWidgets('an environment can be kept in a collection folder', (
    tester,
  ) async {
    final store = WorkspaceStore('unused.json', engine: FakeEngine());
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    store.merge(
      const ImportResult(
        source: 'test',
        warnings: [],
        collections: [
          Collection(
            name: 'Shop',
            variables: [],
            items: [],
            unreviewed: false,
            link: FolderLink(path: '/work/shop', grant: ''),
          ),
          Collection(
            name: 'Loose',
            variables: [],
            items: [],
            unreviewed: false,
          ),
        ],
        environments: [Environment(name: 'Local', variables: [])],
      ),
    );
    await tester.pumpWidget(MaterialApp(home: EnvironmentsPage(store: store)));
    await tester.pumpAndSettle();

    // Only collections kept in a folder are offered.
    await tester.tap(find.byKey(const Key('env-kept-in')));
    await tester.pumpAndSettle();
    expect(find.text('The folder of Loose'), findsNothing);
    await tester.tap(find.text('The folder of Shop').last);
    await tester.pumpAndSettle();
    expect(store.environments.single.folder, '/work/shop');

    // An edit keeps it there.
    await tester.enterText(find.byKey(const Key('env-variables')), 'a=1');
    await tester.pumpAndSettle();
    expect(store.environments.single.folder, '/work/shop');
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('variables typed into an environment are kept', (tester) async {
    final store = WorkspaceStore('unused.json', engine: FakeEngine());
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    store.merge(
      const ImportResult(
        source: 'test',
        warnings: [],
        collections: [],
        environments: [
          Environment(
            name: 'Local',
            variables: [
              Variable(key: 'a', value: '1', enabled: true, secret: false),
            ],
          ),
        ],
      ),
    );
    await tester.pumpWidget(MaterialApp(home: EnvironmentsPage(store: store)));
    await tester.pumpAndSettle();

    // Showing an environment is not an edit of it.
    final shown = store.environments;
    final field = find.byKey(const Key('env-variables'));
    expect(tester.widget<TextField>(field).controller!.text, 'a=1');
    expect(identical(store.environments, shown), isTrue);

    await tester.enterText(field, 'a=2\n# b=3\nsecret token=xyz');
    await tester.pumpAndSettle();
    final variables = store.environments.single.variables;
    expect(
      [for (final v in variables) (v.key, v.value, v.enabled, v.secret)],
      [
        ('a', '2', true, false),
        ('b', '3', false, false),
        ('token', 'xyz', true, true),
      ],
    );
    // Lets the save that follows an edit run.
    await tester.pump(const Duration(seconds: 1));
  });
}
