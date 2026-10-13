import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/environments/environments.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
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
