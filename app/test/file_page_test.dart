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

  testWidgets('a binary file is shown as text only when asked', (tester) async {
    File(path).writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 13]);
    await start(tester);
    expect(find.text('notes.json looks like a binary file.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-binary-open')));
    await settle(tester);
    expect(find.byKey(const Key('file')), findsOneWidget);
  }, variant: _mac);

  testWidgets('a file that cannot be read says why', (tester) async {
    pickDocumentPath = () async => '${dir.path}/missing.txt';
    await start(tester);
    expect(find.textContaining('could not be opened'), findsOneWidget);
    expect(find.text('Open another file…'), findsOneWidget);
  }, variant: _mac);
}
