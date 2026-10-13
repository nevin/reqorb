import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/shared/folders.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

/// Stands in for the system's folder picker and its permissions.
class FakeFolders implements Folders {
  /// What the next press of Choose picks; null cancels.
  String? next;
  final asked = <String?>[];

  /// Grants handed out, and what each one opens after a restart.
  final grants = <String, String?>{};

  @override
  Future<String?> choose({String? initial}) async {
    asked.add(initial);
    return next;
  }

  @override
  Future<String> grant(String path) async {
    grants['grant:$path'] = path;
    return 'grant:$path';
  }

  @override
  Future<String?> restore(String grant) async => grants[grant];
}

const _full = DirAccess(exists: true, readable: true, writable: true);
const _readOnly = DirAccess(exists: true, readable: true, writable: false);

void main() {
  late FakeEngine engine;
  late WorkspaceStore store;
  late FakeFolders picker;

  setUp(() {
    picker = FakeFolders();
    final real = folders;
    folders = picker;
    addTearDown(() => folders = real);
  });

  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
    engine.directories['/work/api-files'] = _full;
    store = WorkspaceStore('/tmp/workspace.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    await tester.tap(find.byKey(const Key('settings')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String? path) async {
    picker.next = path;
    await tester.tap(find.byKey(const Key('settings-working-dir-choose')));
    await tester.pumpAndSettle();
  }

  String status(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('settings-working-dir-status')))
      .data!;

  Switch outside(WidgetTester tester) =>
      tester.widget<Switch>(find.byKey(const Key('settings-allow-outside')));

  testWidgets('the working directory comes first in General', (tester) async {
    await open(tester);
    final directory = tester.getTopLeft(find.text('Working directory')).dy;
    final request = tester.getTopLeft(find.text('Request')).dy;
    expect(directory, lessThan(request));
    expect(find.text('No folder chosen'), findsOneWidget);
    expect(status(tester), startsWith('No folder chosen'));
    // With no folder there is nothing to keep requests inside of.
    expect((outside(tester).value, outside(tester).onChanged), (true, null));
  });

  testWidgets('choosing a folder asks for it and keeps the permission', (
    tester,
  ) async {
    await open(tester);
    await choose(tester, null);
    expect(store.settings.workingDir, '');

    await choose(tester, '/work/api-files');
    expect(find.text('/work/api-files'), findsOneWidget);
    expect(status(tester), 'reqorb can read and write this folder.');
    expect(
      (store.settings.workingDir, store.settings.workingDirGrant),
      ('/work/api-files', 'grant:/work/api-files'),
    );
    expect(WorkingDir.path, '/work/api-files');
    // Requests are kept to the folder until told otherwise.
    expect(outside(tester).value, isFalse);
    expect(store.settings.allowOutsideWorkingDir, isFalse);
    expect(
      find.byKey(const Key('settings-allow-outside-warning')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('settings-allow-outside')));
    await tester.pumpAndSettle();
    expect(store.settings.allowOutsideWorkingDir, isTrue);
    expect(
      find.byKey(const Key('settings-allow-outside-warning')),
      findsOneWidget,
    );

    // The next time, the picker opens where the folder is.
    await choose(tester, null);
    expect(picker.asked.last, '/work/api-files');
    await tester.pump(const Duration(seconds: 1));
    expect(engine.saved!.settings.workingDir, '/work/api-files');

    await tester.tap(find.byKey(const Key('settings-working-dir-clear')));
    await tester.pumpAndSettle();
    expect(
      (store.settings.workingDir, store.settings.workingDirGrant),
      ('', ''),
    );
    // Let the last change be written before the test ends.
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('says when a folder cannot be used and offers to fix it', (
    tester,
  ) async {
    await open(tester);
    await choose(tester, '/work/gone');
    expect(status(tester), startsWith('reqorb cannot open this folder'));

    // Giving access is choosing the folder again; this time it works.
    engine.directories['/work/gone'] = _full;
    picker.next = '/work/gone';
    await tester.tap(find.byKey(const Key('settings-working-dir-grant')));
    await tester.pumpAndSettle();
    expect(status(tester), 'reqorb can read and write this folder.');
    expect(find.byKey(const Key('settings-working-dir-grant')), findsNothing);

    engine.directories['/work/read-only'] = _readOnly;
    await choose(tester, '/work/read-only');
    expect(status(tester), contains('can read this folder but not write'));
  });

  testWidgets('requests are sent with the working directory', (tester) async {
    await open(tester);
    await choose(tester, '/work/api-files');
    await tester.tap(find.byKey(const Key('settings-close')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('url')), 'https://api.test');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
    final sent = engine.sentSettings.single;
    expect(
      (sent.workingDir, sent.allowOutsideWorkingDir),
      ('/work/api-files', false),
    );
  });

  test('a file inside the working directory is kept as a relative path', () {
    addTearDown(() => WorkingDir.path = '');
    WorkingDir.path = '/work/api-files';
    expect(WorkingDir.relative('/work/api-files/img/a.png'), 'img/a.png');
    expect(WorkingDir.relative('/work/api-files-old/a.png'), isNot('a.png'));
    expect(WorkingDir.relative('/elsewhere/a.png'), '/elsewhere/a.png');
    WorkingDir.path = '/work/api-files/';
    expect(WorkingDir.relative('/work/api-files/a.png'), 'a.png');
    WorkingDir.path = r'C:\work';
    expect(WorkingDir.relative(r'C:\work\a.png'), 'a.png');
    WorkingDir.path = '';
    expect(WorkingDir.relative('/any/a.png'), '/any/a.png');
  });

  test(
    'permission is taken up again at startup, following a moved folder',
    () async {
      final store = WorkspaceStore('unused.json', engine: FakeEngine());
      await store.restoreWorkingDir(picker);
      expect(store.settings.workingDir, '');

      store.updateSettings(
        store.settings.copyWith(workingDir: '/old/place', workingDirGrant: 'g'),
      );
      // A grant that no longer works leaves the setting for the user to fix.
      await store.restoreWorkingDir(picker);
      expect(store.settings.workingDir, '/old/place');

      picker.grants['g'] = '/new/place';
      await store.restoreWorkingDir(picker);
      expect(store.settings.workingDir, '/new/place');
      await store.flush();
    },
  );
}
