import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late WorkspaceStore store;

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1400, 1000),
  }) async {
    store = WorkspaceStore('unused.json', engine: FakeEngine());
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    await tester.pumpAndSettle();
  }

  Request request(String url) => Request(
    method: 'GET',
    url: url,
    headers: const [],
    form: const [],
    tests: const [],
    captures: const [],
  );

  testWidgets('the divider between request and response can be dragged', (
    tester,
  ) async {
    // Narrow enough that the response sits below the request.
    await open(tester, size: const Size(1000, 900));
    expect(find.byKey(const Key('split-grip')), findsOneWidget);
    final handle = find.byKey(const Key('split-handle'));
    final before = tester.getCenter(handle).dy;

    await tester.drag(handle, const Offset(0, 150));
    await tester.pumpAndSettle();
    // All but the little a drag takes to be recognised as one.
    expect(tester.getCenter(handle).dy, closeTo(before + 150, 25));

    // The request cannot be squeezed out of reach.
    await tester.drag(handle, const Offset(0, -2000));
    await tester.pumpAndSettle();
    final top = tester.getCenter(handle).dy;
    expect(top, lessThan(before));
    expect(
      tester.getTopLeft(find.byKey(const Key('params-tab'))).dy,
      lessThan(top),
    );

    // Two taps put it back where it started.
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(tester.getCenter(handle).dy, closeTo(before, 2));
    expect(tester.takeException(), isNull);
    // Lets the settings it saved be written.
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the divider stays where it was left, from one launch to the '
      'next', (tester) async {
    await open(tester, size: const Size(1000, 900));
    final handle = find.byKey(const Key('split-handle'));
    final before = tester.getCenter(handle).dy;
    await tester.drag(handle, const Offset(0, 150));
    await tester.pumpAndSettle();
    final left = tester.getCenter(handle).dy;
    expect(store.settings.splitPercent, greaterThan(40));

    // A new start, with the settings as they were saved.
    final settings = store.settings;
    store = WorkspaceStore('unused.json', engine: FakeEngine());
    store.updateSettings(settings);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(ReqorbApp(store: store));
    await tester.pumpAndSettle();
    expect(tester.getCenter(handle).dy, closeTo(left, 6));
    expect(tester.getCenter(handle).dy, isNot(closeTo(before, 50)));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('sections that do not fit can still be reached', (tester) async {
    // The response below the request leaves room for every section.
    await open(tester, size: const Size(1400, 900));
    store.updateSettings(store.settings.copyWith(layout: Layout.stacked));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-tabs')), findsNothing);
    await tester.pumpWidget(const SizedBox());

    // Too narrow: the last of them are out of sight, and a button says so.
    await open(tester, size: const Size(560, 900));
    expect(find.byKey(const Key('more-tabs')), findsOneWidget);
    await tester.tap(find.byKey(const Key('more-tabs')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scripts').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pre-script')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a long sidebar shows that it scrolls', (tester) async {
    await open(tester);
    for (var i = 0; i < 60; i++) {
      store.addStandaloneRequest('Request $i', request('https://api.test/$i'));
    }
    await tester.pumpAndSettle();
    final bar = tester.widget<Scrollbar>(
      find.descendant(
        of: find.byKey(const Key('sidebar')),
        matching: find.byType(Scrollbar),
      ),
    );
    expect(bar.thumbVisibility, isTrue);
    // There is more than fits, and the list can be moved to reach it.
    expect(find.text('Request 59'), findsNothing);
    final position = bar.controller!.position;
    expect(position.maxScrollExtent, greaterThan(0));
    bar.controller!.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('Request 59'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
