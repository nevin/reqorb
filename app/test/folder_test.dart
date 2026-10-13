import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/shared/folders.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';
import 'working_directory_test.dart' show FakeFolders;

void main() {
  late FakeEngine engine;
  late WorkspaceStore store;
  late FakeFolders picker;
  late Folders real;

  Item leaf(String name, String url) => Item(
    name: name,
    request: Request(
      method: 'GET',
      url: url,
      headers: const [],
      form: const [],
      tests: const [],
      captures: const [],
    ),
    items: const [],
  );

  Collection shop([List<Item>? items]) => Collection(
    name: 'Shop',
    variables: const [],
    items: items ?? [leaf('Login', 'https://api.test/login')],
  );

  setUp(() {
    real = folders;
    folders = picker = FakeFolders();
  });
  tearDown(() => folders = real);

  /// The app with one collection, Shop.
  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
    store = WorkspaceStore('unused.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    store.insertCollection(0, shop());
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String key) async {
    await tester.tap(find.byTooltip('Collection actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  /// Lets a pending save, and the folder write that follows it, happen.
  Future<void> saved(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('keeps a collection in a folder and writes its changes there', (
    tester,
  ) async {
    await open(tester);
    picker.next = '/work/shop';
    await menu(tester, 'link-collection');
    await saved(tester);

    expect(store.collections.single.link!.path, '/work/shop');
    expect(store.collections.single.link!.grant, 'grant:/work/shop');
    expect(find.byKey(const Key('folder-mark')), findsOneWidget);
    expect(engine.folderFiles['/work/shop']!.items.single.name, 'Login');
    expect(engine.folderWrites['/work/shop'], 1);

    // A change to the collection reaches the folder; anything else that
    // is saved leaves it alone.
    store.renameCollection(0, 'Store');
    await saved(tester);
    expect(engine.folderFiles['/work/shop']!.name, 'Store');
    expect(engine.folderWrites['/work/shop'], 2);
    store.addStandaloneRequest('Ping', leaf('Ping', 'x').request!);
    await saved(tester);
    expect(engine.folderWrites['/work/shop'], 2);

    // Unlinked, it is no longer written, and the files stay.
    await menu(tester, 'unlink-collection');
    store.renameCollection(0, 'Shop again');
    await saved(tester);
    expect(store.collections.single.link, isNull);
    expect(find.byKey(const Key('folder-mark')), findsNothing);
    expect(engine.folderFiles['/work/shop']!.name, 'Store');
  });

  testWidgets('reads a folder again after its files have changed', (
    tester,
  ) async {
    await open(tester);
    picker.next = '/work/shop';
    await menu(tester, 'link-collection');
    await saved(tester);

    // As a pull would leave it: another request beside the first.
    engine.folderFiles['/work/shop'] = shop([
      leaf('Login', 'https://api.test/login'),
      leaf('Logout', 'https://api.test/logout'),
    ]);
    expect(find.text('Logout'), findsNothing);
    await menu(tester, 'reload-collection');
    await saved(tester);
    expect(find.text('Logout'), findsOneWidget);
    expect(store.collections.single.link!.path, '/work/shop');
    // What was read is what is there, so nothing is written back.
    expect(engine.folderWrites['/work/shop'], 1);
  });

  testWidgets('opens a collection that someone else keeps in a folder', (
    tester,
  ) async {
    await open(tester);
    engine.folderFiles['/work/theirs'] = Collection(
      name: 'Theirs',
      variables: const [],
      items: [leaf('Status', 'https://api.test/status')],
    );
    picker.next = '/work/theirs';
    await tester.tap(find.byKey(const Key('import-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-folder')));
    await tester.pumpAndSettle();
    await saved(tester);

    expect(find.text('Theirs'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
    expect(store.collections.last.link!.path, '/work/theirs');
    expect(engine.folderWrites['/work/theirs'], isNull);

    // A collection is not put on top of the one that folder holds.
    await menu(tester, 'link-collection');
    expect(find.textContaining('already holds a collection'), findsOneWidget);
    expect(store.collections.first.link, isNull);
  });

  testWidgets('says so when a folder cannot be written, and recovers', (
    tester,
  ) async {
    await open(tester);
    picker.next = '/work/shop';
    await menu(tester, 'link-collection');
    await saved(tester);

    engine.folderFailure = 'the disk is full';
    store.renameCollection(0, 'Store');
    await saved(tester);
    expect(find.byKey(const Key('folder-problem')), findsOneWidget);
    expect(store.folderProblems['/work/shop'], 'the disk is full');
    // The change itself is safe in the workspace.
    expect(store.collections.single.name, 'Store');

    engine.folderFailure = null;
    store.renameCollection(0, 'Shop');
    await saved(tester);
    expect(find.byKey(const Key('folder-problem')), findsNothing);
    expect(engine.folderFiles['/work/shop']!.name, 'Shop');
  });

  test('takes linked folders up again after a restart', () async {
    engine = FakeEngine();
    picker.grants['grant:/old/shop'] = '/moved/shop';
    engine.folderFiles['/moved/shop'] = shop([leaf('Pulled', 'x')]);
    engine.saved = Workspace(
      collections: [
        Collection(
          name: 'Shop',
          variables: const [],
          items: [leaf('Login', 'x')],
          link: const FolderLink(path: '/old/shop', grant: 'grant:/old/shop'),
        ),
      ],
      requests: const [],
      environments: const [],
      settings: engine.defaultSettings(),
      cookies: const [],
    );
    store = WorkspaceStore('unused.json', engine: engine);
    await store.load();
    await store.restoreLinks(picker);

    // The folder had moved, and its files had changed.
    final collection = store.collections.single;
    expect(collection.link!.path, '/moved/shop');
    expect(collection.items.single.name, 'Pulled');
    await store.flush();
    store.dispose();
  });
}
