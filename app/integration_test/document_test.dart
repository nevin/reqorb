import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reqorb/bridge/rust_document.dart';
import 'package:reqorb/editor/document_view.dart';
import 'package:reqorb/src/rust/frb_generated.dart';

import '../test/document_conformance.dart';

/// The documents the Rust engine holds do all that the editor relies on,
/// as the ones held in Dart for the widget tests do.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  group('RustDocument', () {
    documentConformance(
      (text) async => RustDocument.of(text),
      RustDocument.open,
    );
  });

  testWidgets('shows, scrolls through and searches a 100 MB file', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('reqorb_big');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/big.json';
    final record = '{"id": 1234567, "name": "an ordinary record", "ok": true}';
    const lines = 1700000;
    // Written in one go, outside the test's clock.
    await tester.runAsync(
      () =>
          File(path)
              .writeAsString('${'$record\n' * lines}{"last": "the needle"}'),
    );

    final started = DateTime.now();
    final document = await tester.runAsync(() => RustDocument.open(path));
    addTearDown(document!.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentView(name: 'big', document: document),
        ),
      ),
    );
    await tester.pump();
    expect(find.text(record), findsWidgets);
    final opened = DateTime.now().difference(started);
    expect(opened, lessThan(const Duration(seconds: 1)));

    // Every line is found in the background.
    for (var i = 0; i < 100 && document.info().indexingDone == false; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(document.info().lineCount, lines + 1);
    expect(find.byKey(const Key('big-indexing')), findsNothing);

    await tester.tap(find.text(record).first);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(find.text('{"last": "the needle"}'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    await tester.tap(find.byKey(const Key('big-find')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('big-find-field')), 'needle');
    String count() =>
        tester.widget<Text>(find.byKey(const Key('big-find-count'))).data!;
    for (var i = 0; i < 100 && count() != '1 of 1'; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(count(), '1 of 1');
    expect(find.text('{"last": "the needle"}'), findsOneWidget);
  });
}
