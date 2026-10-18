import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/document/memory_document.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/document_view.dart';
import 'package:reqorb/editor/syntax.dart';

import 'document_input.dart';

/// A document still being read, as a large file is for a moment after it
/// opens: its lines come in as the test says.
class _Reading extends MemoryDocument {
  _Reading(super.text);

  bool done = false;

  @override
  DocInfo info() {
    final info = super.info();
    return DocInfo(
      len: info.len,
      lineCount: done ? info.lineCount : 1,
      rowCount: done ? info.rowCount : 1,
      version: info.version + (done ? 1 : 0),
      modified: false,
      canUndo: false,
      canRedo: false,
      indexed: done ? info.len : info.len ~/ 4,
      indexingDone: done,
    );
  }
}

void main() {
  late List<String> copied;

  late int changes;

  Future<void> show(
    WidgetTester tester,
    TextDocument document, {
    ValueListenable<int?>? lineSought,
    bool editable = false,
  }) async {
    changes = 0;
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    copied = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentView(
            name: 'doc',
            document: document,
            lineSought: lineSought,
            editable: editable,
            status: editable,
            onChanged: () => changes++,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  String number(WidgetTester tester, int row) =>
      tester.widget<Text>(find.byKey(ValueKey('doc-number-$row'))).data!;

  /// Where a column of a row is on screen, in the font the view uses.
  Offset at(WidgetTester tester, String text, int row, int col) {
    final shown = find.text(text);
    final box = tester.getRect(shown.first);
    final painter = TextPainter(
      text: TextSpan(text: text, style: tester.widget<Text>(shown.first).style),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = painter
        .getOffsetForCaret(TextPosition(offset: col), Rect.zero)
        .dx;
    return Offset(box.left + x + 1, box.center.dy);
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    LogicalKeyboardKey modifier = LogicalKeyboardKey.meta,
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(modifier);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  /// Control, which edits with on the platform tests run as.
  const control = LogicalKeyboardKey.control;

  Future<void> key(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
  }

  String status(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const Key('doc-status')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  testWidgets('shows only the rows in view, numbering lines', (tester) async {
    final text = [for (var i = 1; i <= 10000; i++) 'line $i'].join('\n');
    await show(tester, MemoryDocument(text));
    expect(find.text('line 1'), findsOneWidget);
    expect(find.text('line 10000'), findsNothing);
    expect(number(tester, 0), '1');
    // Far fewer rows built than there are lines.
    expect(
      find.byWidgetPredicate((w) => w.key.toString().contains('doc-number')),
      findsWidgets,
    );
    expect(find.text('line 200'), findsNothing);

    await tester.tap(find.text('line 1'));
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(find.text('line 10000'), findsOneWidget);
  });

  testWidgets('a long line goes on over rows without numbers', (tester) async {
    final long = List.filled(3000, 'ab').join(',');
    await show(tester, MemoryDocument('first\n$long\nlast'));
    // 8999 bytes: five rows of at most 2048.
    expect(
      [for (var row = 0; row < 7; row++) number(tester, row)],
      ['1', '2', '', '', '', '', '3'],
    );
    expect(find.text('last'), findsOneWidget);
  });

  testWidgets('selects with clicks, and copies', (tester) async {
    await show(tester, MemoryDocument('alpha beta gamma\nsecond line'));
    final row = 'alpha beta gamma';

    // A double click selects a word.
    await tester.tapAt(at(tester, row, 0, 7));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at(tester, row, 0, 7));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyC);
    expect(copied.last, 'beta');

    // A third click selects the line.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at(tester, row, 0, 7));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyC);
    expect(copied.last, 'alpha beta gamma');

    // Dragging selects from where it began.
    await tester.pump(const Duration(seconds: 1));
    final drag = await tester.startGesture(
      at(tester, row, 0, 6),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(at(tester, 'second line', 1, 6));
    await drag.up();
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyC);
    expect(copied.last, 'beta gamma\nsecond');

    await press(tester, LogicalKeyboardKey.keyA);
    await press(tester, LogicalKeyboardKey.keyC);
    expect(copied.last, 'alpha beta gamma\nsecond line');
  });

  testWidgets('finds, counts and steps through matches', (tester) async {
    final text = [for (var i = 0; i < 2000; i++) 'row $i: Cat or cat']
        .join('\n');
    await show(tester, MemoryDocument(text));
    await tester.tap(find.byKey(const Key('doc-find')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('doc-find-field')), 'cat');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    String count() =>
        tester.widget<Text>(find.byKey(const Key('doc-find-count'))).data!;
    expect(count(), '1 of 4000');

    await tester.tap(find.byKey(const Key('doc-find-case')));
    await tester.pump();
    await tester.pump();
    expect(count(), '1 of 2000');

    // Stepping back from the first goes round to the last, far below.
    await tester.tap(find.byKey(const Key('doc-find-previous')));
    await tester.pump();
    expect(count(), '2000 of 2000');
    expect(find.text('row 1999: Cat or cat'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.keyC);
    await tester.tap(find.byKey(const Key('doc-find-next')));
    await tester.pump();
    expect(count(), '1 of 2000');

    await tester.tap(find.byKey(const Key('doc-find-regex')));
    await tester.enterText(find.byKey(const Key('doc-find-field')), '(');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(count(), 'Not a valid pattern');

    await tester.enterText(find.byKey(const Key('doc-find-field')), 'nothing');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(count(), 'None');

    await tester.tap(find.byKey(const Key('doc-find-close')));
    await tester.pump();
    expect(find.byKey(const Key('doc-find-field')), findsNothing);
  });

  testWidgets('goes to a line asked for', (tester) async {
    final text = [for (var i = 1; i <= 5000; i++) 'line $i'].join('\n');
    final sought = ValueNotifier<int?>(null);
    addTearDown(sought.dispose);
    await show(tester, MemoryDocument(text), lineSought: sought);
    sought.value = 4321;
    await tester.pump();
    await tester.pump();
    expect(find.text('line 4321'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.keyC);
    expect(copied.last, 'line 4321');
  });

  testWidgets('shows how far reading a file has got', (tester) async {
    final document = _Reading('a\nb\nc');
    await show(tester, document);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('doc-indexing')),
    );
    expect(progress.value, closeTo(0.2, 0.01));
    expect(find.text('b'), findsNothing);

    document.done = true;
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const Key('doc-indexing')), findsNothing);
    expect(find.text('c'), findsOneWidget);
  });

  testWidgets('a view made from text makes its document and lets it go', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DocumentText(name: 'doc', text: '{"a": 1}'),
        ),
      ),
    );
    expect(find.text('{"a": 1}'), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DocumentText(name: 'doc', text: 'changed'),
        ),
      ),
    );
    expect(find.text('changed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('editing', () {
    testWidgets('types, rubs out and moves the caret', (tester) async {
      final doc = MemoryDocument('first\nsecond');
      await show(tester, doc, editable: true);
      await tester.tapAt(at(tester, 'first', 0, 5));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      // Told only the caret's row.
      expect(told(tester).text, 'first');
      expect(told(tester).selection, const TextSelection.collapsed(offset: 5));

      await input(tester, '!');
      await input(tester, 'é');
      expect(doc.text(0, 99), 'first!é\nsecond');
      expect(find.text('first!é'), findsOneWidget);
      expect(changes, 2);
      expect(status(tester), startsWith('Ln 1, Col 8'));

      await key(tester, LogicalKeyboardKey.backspace);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.arrowLeft, shift: true);
      await key(tester, LogicalKeyboardKey.backspace);
      expect(doc.text(0, 99), 'firs!\nsecond');

      // Down keeps as far across as it can, and on to the end.
      await key(tester, LogicalKeyboardKey.arrowDown);
      await input(tester, '-');
      expect(doc.text(0, 99), 'firs!\nseco-nd');
      await key(tester, LogicalKeyboardKey.end);
      await key(tester, LogicalKeyboardKey.delete);
      await input(tester, '.');
      expect(doc.text(0, 99), 'firs!\nseco-nd.');
      expect(told(tester).text, 'seco-nd.');

      // By word, with Control here, as on Windows and Linux: what is
      // between, and the word before it.
      await tester.sendKeyDownEvent(control);
      await key(tester, LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(control);
      expect(doc.text(0, 99), 'firs!\nseco-');
    });

    testWidgets('a new line keeps the indentation, and more in brackets', (
      tester,
    ) async {
      final doc = MemoryDocument('{\n  "a": [1]\n}');
      await show(tester, doc, editable: true);
      await tester.tapAt(at(tester, '  "a": [1]', 1, 8));
      await tester.pump();
      await key(tester, LogicalKeyboardKey.enter);
      expect(doc.text(0, 99), '{\n  "a": [\n    1]\n}');
      await input(tester, '0, ');
      expect(doc.text(0, 99), '{\n  "a": [\n    0, 1]\n}');
    });

    testWidgets('undoes and does again', (tester) async {
      final doc = MemoryDocument('abc');
      await show(tester, doc, editable: true);
      await tester.tapAt(at(tester, 'abc', 0, 3));
      await tester.pump();
      for (final c in 'def'.split('')) {
        await input(tester, c);
      }
      await key(tester, LogicalKeyboardKey.backspace);
      expect(doc.text(0, 99), 'abcde');

      await press(tester, LogicalKeyboardKey.keyZ, modifier: control);
      expect(doc.text(0, 99), 'abcdef');
      await press(tester, LogicalKeyboardKey.keyZ, modifier: control);
      expect(doc.text(0, 99), 'abc', reason: 'typing undoes a run at a time');
      expect(doc.info().modified, isFalse);
      await press(
        tester,
        LogicalKeyboardKey.keyZ,
        modifier: control,
        shift: true,
      );
      expect(doc.text(0, 99), 'abcdef');
      await press(tester, LogicalKeyboardKey.keyY, modifier: control);
      expect(doc.text(0, 99), 'abcde');
      // The caret follows, and typing goes on from it.
      await input(tester, '!');
      expect(doc.text(0, 99), 'abcde!');
    });

    testWidgets('composes with the input method', (tester) async {
      final doc = MemoryDocument('ab');
      await show(tester, doc, editable: true);
      await tester.tapAt(at(tester, 'ab', 0, 1));
      await tester.pump();
      // Japanese: "n", then "に", still being chosen, then chosen.
      await input(tester, 'n', composing: const TextRange(start: 1, end: 2));
      expect(doc.text(0, 99), 'anb');
      // Keys go to the input method while it composes.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(doc.text(0, 99), 'anb');
      await input(
        tester,
        'に',
        start: 1,
        end: 2,
        composing: const TextRange(start: 1, end: 2),
      );
      expect(doc.text(0, 99), 'aにb');
      expect(told(tester).composing, const TextRange(start: 1, end: 2));
      await input(tester, '', start: 2, end: 2);
      expect(doc.text(0, 99), 'aにb');
      await key(tester, LogicalKeyboardKey.backspace);
      expect(doc.text(0, 99), 'ab');
    });

    testWidgets('cuts, copies and pastes', (tester) async {
      final doc = MemoryDocument('one two');
      await show(tester, doc, editable: true);
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') {
            return {'text': clipboard};
          }
          return null;
        },
      );
      await tester.tapAt(at(tester, 'one two', 0, 1));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at(tester, 'one two', 0, 1));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyX, modifier: control);
      expect(clipboard, 'one');
      expect(doc.text(0, 99), ' two');
      await key(tester, LogicalKeyboardKey.end);
      await press(tester, LogicalKeyboardKey.keyV, modifier: control);
      expect(doc.text(0, 99), ' twoone');
    });

    testWidgets('indents and outdents lines', (tester) async {
      final doc = MemoryDocument('a\nb\n\nc');
      await show(tester, doc, editable: true);
      await tester.tapAt(at(tester, 'a', 0, 0));
      await tester.pump();
      await key(tester, LogicalKeyboardKey.tab);
      expect(doc.text(0, 99), '  a\nb\n\nc');
      await press(tester, LogicalKeyboardKey.keyA, modifier: control);
      await key(tester, LogicalKeyboardKey.tab);
      expect(doc.text(0, 99), '    a\n  b\n\n  c');
      // One step, undone at once.
      await press(tester, LogicalKeyboardKey.keyZ, modifier: control);
      expect(doc.text(0, 99), '  a\nb\n\nc');
      await press(tester, LogicalKeyboardKey.keyA, modifier: control);
      await key(tester, LogicalKeyboardKey.tab, shift: true);
      expect(doc.text(0, 99), 'a\nb\n\nc');
    });

    testWidgets('replaces one match and then all', (tester) async {
      final doc = MemoryDocument('cat dog cat\ncat');
      await show(tester, doc, editable: true);
      await tester.tapAt(at(tester, 'cat dog cat', 0, 0));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyF);
      await tester.tap(find.byKey(const Key('doc-replace-toggle')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('doc-find-field')), 'cat');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('doc-replace-field')),
        'bird',
      );
      await tester.tap(find.byKey(const Key('doc-replace-one')));
      await tester.pump();
      await tester.pump();
      expect(doc.text(0, 99), 'bird dog cat\ncat');
      String count() =>
          tester.widget<Text>(find.byKey(const Key('doc-find-count'))).data!;
      expect(count(), '1 of 2');

      await tester.tap(find.byKey(const Key('doc-replace-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(doc.text(0, 99), 'bird dog bird\nbird');
      expect(find.text('Replaced 2'), findsOneWidget);
      expect(count(), 'None');
      // All in one step.
      await tester.tapAt(at(tester, 'bird dog bird', 0, 0));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyZ, modifier: control);
      expect(doc.text(0, 99), 'bird dog cat\ncat');
    });

    testWidgets('typing over a selection too big to tell replaces it', (
      tester,
    ) async {
      final text = [for (var i = 0; i < 100; i++) 'line $i'].join('\n');
      final doc = MemoryDocument(text);
      await show(tester, doc, editable: true);
      await tester.tapAt(at(tester, 'line 0', 0, 0));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyA, modifier: control);
      expect(told(tester).text, '');
      expect(status(tester), contains('selected'));
      await input(tester, 'x');
      expect(doc.text(0, 999), 'x');
      await input(tester, 'y');
      expect(doc.text(0, 999), 'xy');
    });

    testWidgets('a view that cannot be edited takes no typing', (tester) async {
      await show(tester, MemoryDocument('fixed'));
      await tester.tapAt(at(tester, 'fixed', 0, 2));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(find.byKey(const Key('doc-status')), findsNothing);
    });

    testWidgets('moves by word with Option on macOS', (tester) async {
      final doc = MemoryDocument('alpha beta gamma');
      await show(tester, doc, editable: true);
      await tester.tapAt(at(tester, 'alpha beta gamma', 0, 0));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.alt);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.alt);
      await input(tester, '!');
      expect(doc.text(0, 99), 'alpha beta! gamma');
      // Command goes to the end of the row.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await input(tester, '>');
      expect(doc.text(0, 99), '>alpha beta! gamma');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  testWidgets('marks the partner of the bracket beside the caret', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentView(
            name: 'doc',
            document: MemoryDocument('{"a": [1, "]", 2]}'),
            language: CodeLanguage.json,
            editable: true,
          ),
        ),
      ),
    );
    // Just after the opening `[`, at byte 7.
    await tester.tapAt(at(tester, '{"a": [1, "]", 2]}', 0, 7));
    await tester.pump();
    final marked = <(int, int)>[];
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter == null || '${painter.runtimeType}' != '_MarkPainter') {
        continue;
      }
      for (final mark in (painter as dynamic).marks as List) {
        final dynamic m = mark;
        if (m.start + 1 == m.end) marked.add((m.start as int, m.end as int));
      }
    }
    // The `]` in the string is passed over.
    expect(marked, [(6, 7), (16, 17)]);
  });

  testWidgets('opens a web address clicked with Command', (tester) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opened = <Uri>[];
    const row = 'see https://example.com/docs, then';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentView(
            name: 'doc',
            document: MemoryDocument(row),
            onLink: opened.add,
          ),
        ),
      ),
    );
    await tester.tapAt(at(tester, row, 0, 10));
    expect(opened, isEmpty, reason: 'a plain click places the caret');
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.tapAt(at(tester, row, 0, 10));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    expect(opened, [Uri.parse('https://example.com/docs')]);
  });
}
