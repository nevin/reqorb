import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/files/file_page.dart';

import 'document_input.dart';
import 'fake_engine.dart';

/// Where files are saved in place, with Command.
final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('reqorb_file_page');
    path = '${dir.path}/notes.json';
    File(path).writeAsStringSync('{"a": 1}\n');
    pickDocumentPath = () async => path;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Lets reading and writing files, which happen outside the test's
  /// clock, finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  /// The app with a button that opens a file, as the sidebar's does.
  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      EngineScope(
        engine: FakeEngine(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openFile(context),
                child: const Text('Open file'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open file'));
    await settle(tester);
    // The page slides in.
    await tester.pump(const Duration(milliseconds: 500));
  }

  String title(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('file-title'))).data!;

  Future<void> command(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await settle(tester);
  }

  testWidgets('opens a file, edits it and saves it', (tester) async {
    await start(tester);
    expect(find.byKey(const Key('file-page')), findsOneWidget);
    expect(title(tester), 'notes.json');
    expect(find.text('{"a": 1}'), findsOneWidget);
    // Ready to type at once.
    expect(tester.testTextInput.hasAnyClients, isTrue);

    await input(tester, '[');
    expect(title(tester), '• notes.json');
    await command(tester, LogicalKeyboardKey.keyS);
    expect(title(tester), 'notes.json');
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      '[{"a": 1}\n',
    );
    expect(find.text('Saved notes.json'), findsWidgets);
  }, variant: _mac);

  testWidgets('asks before closing with changes', (tester) async {
    await start(tester);
    await input(tester, 'x');
    await command(tester, LogicalKeyboardKey.keyW);
    expect(find.text('Save the changes to notes.json?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.byKey(const Key('file-page')), findsOneWidget);

    await command(tester, LogicalKeyboardKey.keyW);
    await tester.tap(find.byKey(const Key('file-discard')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('file-page')), findsNothing);
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      '{"a": 1}\n',
    );
  }, variant: _mac);

  testWidgets('saves a copy elsewhere, and goes on with it', (tester) async {
    final copy = '${dir.path}/copy.json';
    chooseSavePath = (name) async {
      expect(name, 'notes.json');
      return copy;
    };
    await start(tester);
    await input(tester, ' ');
    await tester.tap(find.byKey(const Key('file-save-as')));
    await settle(tester);
    expect(title(tester), 'copy.json');
    expect(
      await tester.runAsync(() => File(copy).readAsString()),
      ' {"a": 1}\n',
    );
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      '{"a": 1}\n',
    );
  }, variant: _mac);

  testWidgets('a change made elsewhere is read, or said if there are edits', (
    tester,
  ) async {
    await start(tester);
    await tester.runAsync(() async {
      // A different size, so that it is seen even within the same second.
      await File(path).writeAsString('{"b": 22}\n');
    });
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(find.text('{"b": 22}'), findsOneWidget);
    expect(find.byKey(const Key('file-changed')), findsNothing);

    await input(tester, 'mine ');
    await tester.runAsync(() => File(path).writeAsString('{"c": 333}\n'));
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(find.byKey(const Key('file-changed')), findsOneWidget);
    expect(find.text('mine {"b": 22}'), findsOneWidget);

    // Saving over it asks first.
    await command(tester, LogicalKeyboardKey.keyS);
    expect(find.text('Save over the other changes?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-overwrite')));
    await settle(tester);
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      'mine {"b": 22}\n',
    );
    expect(find.byKey(const Key('file-changed')), findsNothing);
  }, variant: _mac);

  testWidgets('a binary file is shown as bytes, or as text when asked', (
    tester,
  ) async {
    File(path).writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 13]);
    await start(tester);
    expect(find.byKey(const Key('file-hex')), findsOneWidget);
    expect(
      find.text(
        '00000000  89 50 4e 47 00 00 00 0d                           .PNG....',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('file-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('file-view-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('file')), findsOneWidget);
  }, variant: _mac);

  testWidgets('JSON is explored as a tree', (tester) async {
    File(path).writeAsStringSync(
      '{"name": "reqorb", "list": [${List.generate(250, (i) => i).join(', ')}]}',
    );
    await start(tester);
    await tester.tap(find.byKey(const Key('file-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('file-view-tree')));
    await settle(tester);
    expect(find.text('"name": "reqorb"'), findsOneWidget);
    // The list opens a page at a time: after the top, its two keys and
    // the first 200 items, a row brings more.
    await tester.tap(find.textContaining('"list": […]'));
    await settle(tester);
    expect(find.text('0: 0'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('file-tree-more-203')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('file-tree')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const Key('file-tree-more-203')));
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('249: 249'),
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('file-tree')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('249: 249'), findsOneWidget);
  }, variant: _mac);

  testWidgets('a value picked in the tree is shown in the text', (
    tester,
  ) async {
    File(path).writeAsStringSync('{"name": "reqorb", "n": 12345}');
    await start(tester);
    await tester.tap(find.byKey(const Key('file-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('file-view-tree')));
    await settle(tester);
    // Row 2 is "n", after the top and "name".
    await tester.tap(find.byKey(const Key('file-tree-show-2')));
    await settle(tester);
    expect(find.byKey(const Key('file')), findsOneWidget);
    expect(find.textContaining('5 B selected'), findsOneWidget);
  }, variant: _mac);

  testWidgets('formatting says so when there is no room for it', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('reqorb/device'),
      (call) async => call.method == 'freeSpace' ? 1024 * 1024 : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('reqorb/device'),
        null,
      ),
    );
    File(path).writeAsStringSync('[${List.filled(200000, '1').join(',')}]');
    await start(tester);
    await tester.tap(find.byKey(const Key('file-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('file-format')));
    await settle(tester);
    expect(
      find.textContaining('Not enough free space to format notes.json'),
      findsWidgets,
    );
    expect(find.byKey(const Key('file-rewriting')), findsNothing);
  }, variant: _mac);

  testWidgets('JSON is formatted or minified, and saved over the file', (
    tester,
  ) async {
    File(path).writeAsStringSync('{"a":[1,2],"b":{}}');
    await start(tester);
    Future<void> menu(String key) async {
      await tester.tap(find.byKey(const Key('file-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await settle(tester);
      await settle(tester);
    }

    await menu('file-format');
    expect(find.text('  "a": ['), findsOneWidget);
    expect(title(tester), '• notes.json');
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      '{"a":[1,2],"b":{}}',
      reason: 'not written until saved',
    );
    await command(tester, LogicalKeyboardKey.keyS);
    expect(title(tester), 'notes.json');
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      '{\n  "a": [\n    1,\n    2\n  ],\n  "b": {}\n}\n',
    );

    await menu('file-minify');
    await command(tester, LogicalKeyboardKey.keyS);
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      '{"a":[1,2],"b":{}}',
    );
  }, variant: _mac);

  testWidgets('a file that cannot be read says why', (tester) async {
    pickDocumentPath = () async => '${dir.path}/missing.txt';
    await start(tester);
    expect(find.textContaining('could not be opened'), findsOneWidget);
    expect(find.text('Open another file…'), findsOneWidget);
  }, variant: _mac);
}
