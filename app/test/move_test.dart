import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

const _end = 1 << 30;

Request _request(String url) => Request(
  method: 'GET',
  url: url,
  headers: const [],
  form: const [],
  tests: const [],
  captures: const [],
);

Item _item(String name) => Item(
  name: name,
  request: _request('https://api.test/$name'),
  items: const [],
);

void main() {
  group('moving saved requests in the store', () {
    late WorkspaceStore store;

    /// The names in a list of items, folders with theirs in brackets.
    String names(List<Item> items) => items
        .map(
          (item) => item.request == null
              ? '${item.name}[${names(item.items)}]'
              : item.name,
        )
        .join(' ');

    setUp(() {
      store = WorkspaceStore('unused.json', engine: FakeEngine());
      // Shop: a b Folder[c d]; Blog: e; and x y outside any collection.
      store.merge(
        ImportResult(
          source: 'test',
          collections: [
            Collection(
              name: 'Shop',
              unreviewed: false,
              variables: const [],
              items: [
                _item('a'),
                _item('b'),
                Item(name: 'Folder', items: [_item('c'), _item('d')]),
              ],
            ),
            Collection(
              name: 'Blog',
              unreviewed: false,
              variables: const [],
              items: [_item('e')],
            ),
          ],
          environments: const [],
          warnings: const [],
        ),
      );
      store.addStandaloneRequest('x', _request('https://api.test/x'));
      store.addStandaloneRequest('y', _request('https://api.test/y'));
    });
    tearDown(() => store.dispose());

    String shop() => names(store.collections[0].items);
    String blog() => names(store.collections[1].items);
    String outside() => names(store.requests);

    test('up and down among its neighbours', () {
      // b before a.
      expect(
        store.moveItem(const RequestRef(0, [1]), const RequestRef(0, [0])),
        isTrue,
      );
      expect(shop(), 'b a Folder[c d]');
      // b, now first, before the folder: past a, which moves up to make room.
      store.moveItem(const RequestRef(0, [0]), const RequestRef(0, [2]));
      expect(shop(), 'a b Folder[c d]');
      store.moveItem(const RequestRef(0, [0]), const RequestRef(0, [_end]));
      expect(shop(), 'b Folder[c d] a');
    });

    test('into a folder, out of it, and between collections', () {
      store.moveItem(const RequestRef(0, [0]), const RequestRef(0, [2, 1]));
      expect(shop(), 'b Folder[c a d]');
      store.moveItem(const RequestRef(0, [1, 0]), const RequestRef(1, [0]));
      expect(shop(), 'b Folder[a d]');
      expect(blog(), 'c e');
      store.moveItem(const RequestRef(1, [1]), const RequestRef(0, [1, _end]));
      expect(shop(), 'b Folder[a d e]');
      expect(blog(), 'c');
    });

    test('to and from the requests outside any collection', () {
      store.moveItem(
        const RequestRef(0, [0]),
        const RequestRef(RequestRef.noCollection, [1]),
      );
      expect(outside(), 'x a y');
      store.moveItem(RequestRef.standalone(0), const RequestRef(1, [_end]));
      expect(outside(), 'a y');
      expect(blog(), 'e x');
    });

    test('nothing moves to where it is, into itself or to nowhere', () {
      final before = '${shop()} | ${blog()} | ${outside()}';
      expect(
        store.moveItem(const RequestRef(0, [1]), const RequestRef(0, [1])),
        isFalse,
      );
      expect(
        store.moveItem(const RequestRef(0, [2]), const RequestRef(0, [2, 0])),
        isFalse,
      );
      expect(
        store.moveItem(const RequestRef(0, [0]), const RequestRef(7, [0])),
        isFalse,
      );
      // Into a request, which holds nothing.
      expect(
        store.moveItem(const RequestRef(0, [0]), const RequestRef(0, [1, 0])),
        isFalse,
      );
      expect(
        store.moveItem(const RequestRef(0, [9]), const RequestRef(1, [0])),
        isFalse,
      );
      expect('${shop()} | ${blog()} | ${outside()}', before);
    });

    test('an item is found again wherever it has gone', () {
      final d = store.itemAt(const RequestRef(0, [2, 1]))!;
      expect(store.refOf(d), const RequestRef(0, [2, 1]));
      store.moveItem(const RequestRef(0, [2, 1]), const RequestRef(1, [0]));
      expect(store.refOf(d), const RequestRef(1, [0]));
      store.removeItem(const RequestRef(1, [0]));
      expect(store.refOf(d), isNull);
    });
  });

  group('in the app', () {
    late WorkspaceStore store;

    Future<void> open(WidgetTester tester) async {
      store = WorkspaceStore('unused.json', engine: FakeEngine());
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ReqorbApp(store: store));
      addTearDown(() => tester.pump(const Duration(seconds: 5)));
      store.addCollection('Shop');
      for (final name in ['Ping', 'Pong', 'Pang']) {
        store.addStandaloneRequest(name, _request('https://api.test/$name'));
      }
      await tester.pumpAndSettle();
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    /// Holds [from] and lets it go over [to], as a finger does.
    Future<void> drag(WidgetTester tester, Finder from, Finder to) async {
      final gesture = await tester.startGesture(tester.getCenter(from));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(to) + const Offset(0, 4));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(to));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    List<String> outside() => [for (final item in store.requests) item.name];

    String url(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(const Key('url'))).controller!.text;

    testWidgets('a request is dragged before another, and into a collection', (
      tester,
    ) async {
      await open(tester);
      await drag(tester, find.text('Pang'), find.text('Ping'));
      expect(outside(), ['Pang', 'Ping', 'Pong']);

      await drag(tester, find.text('Pong'), find.text('Shop'));
      expect(outside(), ['Pang', 'Ping']);
      expect(store.collections.single.items.single.name, 'Pong');

      // And back out, onto the heading of those outside any collection.
      await drag(tester, find.text('Pong'), find.text('Requests'));
      expect(outside(), ['Pang', 'Ping', 'Pong']);
      expect(store.collections.single.items, isEmpty);
      // What was moved is saved a moment later.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('an open request stays open on the one it was, once moved', (
      tester,
    ) async {
      await open(tester);
      await tap(tester, find.text('Ping'));
      await tap(tester, find.text('Pang'));
      await tester.tap(find.text('Ping').last, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('move-request')));
      expect(find.byKey(const Key('move-to')), findsOneWidget);
      await tap(tester, find.widgetWithText(SimpleDialogOption, 'Shop'));
      expect(outside(), ['Pong', 'Pang']);
      expect(store.collections.single.items.single.name, 'Ping');

      // Both tabs still edit their own requests: saving goes to the right one.
      expect(url(tester), 'https://api.test/Pang');
      await tap(tester, find.byKey(const Key('tab-0')));
      expect(url(tester), 'https://api.test/Ping');
      await tester.enterText(find.byKey(const Key('url')), 'https://moved');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tab-dirty-0')), findsOneWidget);
      await tap(tester, find.byKey(const Key('save')));
      expect(
        store.collections.single.items.single.request!.url,
        'https://moved',
      );
      expect(store.requests[1].request!.url, 'https://api.test/Pang');
    });

    testWidgets('a tab is dragged to another place with a pointer', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await open(tester);
        await tap(tester, find.text('Ping'));
        await tap(tester, find.text('Pong'));
        await tap(tester, find.text('Pang'));
        List<String> tabs() => [
          for (var i = 0; i < 3; i++)
            tester
                .widget<RichText>(find.byKey(Key('tab-name-$i')))
                .text
                .toPlainText(),
        ];
        expect(tabs(), ['Ping', 'Pong', 'Pang']);

        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('tab-name-2'))),
          kind: PointerDeviceKind.mouse,
        );
        final first = tester.getCenter(find.byKey(const Key('tab-name-0')));
        await gesture.moveTo(first + const Offset(20, 0));
        await tester.pump();
        await gesture.moveTo(first);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tabs(), ['Pang', 'Ping', 'Pong']);
        // The tab that was showing still is.
        expect(url(tester), 'https://api.test/Pang');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the sidebar is made wider by its edge, and put back', (
      tester,
    ) async {
      await open(tester);
      double width() => tester.getSize(find.byKey(const Key('sidebar'))).width;
      expect(width(), 281);
      await tester.drag(
        find.byKey(const Key('sidebar-edge')),
        const Offset(80, 0),
      );
      await tester.pumpAndSettle();
      expect(store.settings.sidebarWidth, greaterThan(330));
      expect(width(), store.settings.sidebarWidth + 1);
      // No wider than leaves room for the request.
      await tester.drag(
        find.byKey(const Key('sidebar-edge')),
        const Offset(900, 0),
      );
      await tester.pumpAndSettle();
      expect(store.settings.sidebarWidth, 520);

      await tester.tap(find.byKey(const Key('sidebar-edge')));
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(find.byKey(const Key('sidebar-edge')));
      await tester.pumpAndSettle();
      expect(store.settings.sidebarWidth, 280);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('with nothing saved, the sidebar offers ways to start', (
      tester,
    ) async {
      await open(tester);
      expect(find.byKey(const Key('start-import')), findsNothing);
      store.removeCollection(0);
      await tester.pumpAndSettle();
      for (final key in ['start-import', 'start-paste', 'start-folder']) {
        expect(find.byKey(Key(key)), findsOneWidget);
      }
      await tap(tester, find.byKey(const Key('start-collection')));
      await tester.enterText(find.byType(TextField).last, 'Mine');
      await tap(tester, find.text('Create'));
      expect(store.collections.single.name, 'Mine');
      expect(find.byKey(const Key('start-collection')), findsNothing);
    });

    testWidgets('where there is no menu bar, a button holds the menus', (
      tester,
    ) async {
      await open(tester);
      // A tab with something in it, so that a new request needs its own.
      await tap(tester, find.text('Ping'));
      await tap(tester, find.byKey(const Key('app-menu')));
      await tap(tester, find.byKey(const Key('app-menu-file')));
      await tap(tester, find.byKey(const Key('app-menu-newRequest')));
      expect(find.byKey(const Key('tab-1')), findsOneWidget);

      await tap(tester, find.byKey(const Key('app-menu')));
      await tap(tester, find.byKey(const Key('app-menu-help')));
      await tap(tester, find.byKey(const Key('app-menu-shortcuts')));
      expect(find.byKey(const Key('shortcuts')), findsOneWidget);
    });

    testWidgets('a Mac, which has a menu bar, shows no such button', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await open(tester);
        expect(find.byKey(const Key('app-menu')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
