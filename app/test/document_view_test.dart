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
    await tester.tapAt(at(tester, row, 0, 7), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at(tester, row, 0, 7), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyC);
    expect(copied.last, 'beta');

    // A third click selects the line.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at(tester, row, 0, 7), kind: PointerDeviceKind.mouse);
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
    await tester.tapAt(at(tester, row, 0, 10), kind: PointerDeviceKind.mouse);
    expect(opened, isEmpty, reason: 'a plain click places the caret');
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.tapAt(at(tester, row, 0, 10), kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    expect(opened, [Uri.parse('https://example.com/docs')]);
  });

  group('touch and assistive technology', () {
    testWidgets('a long press selects a word, with handles and a menu', (
      tester,
    ) async {
      final doc = MemoryDocument('alpha beta gamma\nsecond line');
      await show(tester, doc, editable: true);
      const row = 'alpha beta gamma';
      final hold = await tester.startGesture(at(tester, row, 0, 7));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await hold.up();
      await tester.pump();
      expect(find.byKey(const Key('doc-handle-start')), findsOneWidget);
      expect(find.byKey(const Key('doc-handle-end')), findsOneWidget);
      expect(find.byKey(const Key('doc-menu')), findsOneWidget);
      await tester.tap(find.byKey(const Key('doc-menu-copy')));
      await tester.pump();
      expect(copied.last, 'beta');
      expect(find.byKey(const Key('doc-menu')), findsNothing);

      // The end handle drags the selection on.
      final end = tester.getCenter(find.byKey(const Key('doc-handle-end')));
      final target = at(tester, row, 0, 16);
      final drag = await tester.startGesture(end);
      await drag.moveTo(Offset(target.dx, end.dy));
      await drag.up();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyC);
      expect(copied.last, 'beta gamma');

      // A tap places the caret, and the handles go.
      await tester.tapAt(at(tester, 'second line', 1, 3));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('doc-handle-start')), findsNothing);
      await input(tester, '!');
      expect(doc.text(0, 99), 'alpha beta gamma\nsec!ond line');
    });

    testWidgets('dragging on from a long press selects as it goes', (
      tester,
    ) async {
      await show(
        tester,
        MemoryDocument('alpha beta gamma delta'),
        editable: true,
      );
      const row = 'alpha beta gamma delta';
      final finger = await tester.startGesture(at(tester, row, 0, 12));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await finger.moveTo(at(tester, row, 0, 19));
      await tester.pump();
      expect(find.byKey(const Key('doc-menu')), findsNothing);
      await finger.up();
      await tester.pump();
      expect(find.byKey(const Key('doc-menu')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyC);
      expect(copied.last, 'gamma de');
      // And back, before the word pressed.
      final again = await tester.startGesture(at(tester, row, 0, 12));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await again.moveTo(at(tester, row, 0, 2));
      await again.up();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyC);
      expect(copied.last, 'pha beta gamma');
    });

    testWidgets('a right click brings up the menu', (tester) async {
      final doc = MemoryDocument('one two');
      await show(tester, doc, editable: true);
      final click = await tester.startGesture(
        at(tester, 'one two', 0, 1),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await click.up();
      await tester.pump();
      expect(find.byKey(const Key('doc-menu-paste')), findsOneWidget);
      expect(find.byKey(const Key('doc-menu-copy')), findsNothing);
      await tester.tap(find.byKey(const Key('doc-menu-select-all')));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyC);
      expect(copied.last, 'one two');
      // Escape puts it away.
      final again = await tester.startGesture(
        at(tester, 'one two', 0, 1),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await again.up();
      await tester.pump();
      expect(find.byKey(const Key('doc-menu')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('doc-menu')), findsNothing);
    });

    testWidgets('a screen reader hears the lines, and where the caret goes', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final heard = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
            message,
          ) async {
            final data = (message as Map)['data'] as Map;
            if (data['message'] case final String said) heard.add(said);
            return null;
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler(SystemChannels.accessibility, null),
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await show(tester, MemoryDocument('first\n\nthird'), editable: true);
      expect(find.bySemanticsLabel(RegExp('^Line 3')), findsOneWidget);
      await tester.tapAt(
        at(tester, 'first', 0, 2),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(heard, ['Line 1: first', 'Line 2, blank', 'Line 3: third']);
      semantics.dispose();
    });
  });

  group('colours', () {
    /// The colour the start of [text], a row on show, is drawn in.
    Color? colourOf(WidgetTester tester, String text) {
      final shown = tester.widget<Text>(find.text(text));
      var span = shown.textSpan! as TextSpan;
      while (span.children != null && span.children!.isNotEmpty) {
        span = span.children!.first as TextSpan;
      }
      return span.style?.color;
    }

    Future<void> goTo(
      WidgetTester tester,
      String text,
      int line, {
      CodeLanguage? language,
    }) async {
      final sought = ValueNotifier<int?>(null);
      addTearDown(sought.dispose);
      tester.view.physicalSize = const Size(900, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentView(
              name: 'doc',
              document: MemoryDocument(text),
              language: language,
              lineSought: sought,
            ),
          ),
        ),
      );
      sought.value = line;
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a string goes on into the next block of rows', (tester) async {
      // The 128th row, where a block of rows starts, is the second of a
      // long line inside a string the first row opened.
      // `[` and 126 lines take rows 0 to 126; the long line is 127 and 128.
      final lines = [for (var i = 0; i < 126; i++) '{"n": $i},'];
      final long = 'x' * 2048;
      final text = '[\n${lines.join('\n')}\n"$long${'y' * 30}"]';
      await goTo(tester, text, 129);
      final string = tokenColor(
        TokenKind.string,
        Theme.of(tester.element(find.byType(DocumentView))).brightness,
      );
      expect(colourOf(tester, 'x${'y' * 30}"]'), string);
    });

    testWidgets('a comment goes on into the next block of rows', (
      tester,
    ) async {
      final text = [
        for (var i = 0; i < 120; i++) 'let a$i = $i;',
        '/* a note',
        for (var i = 0; i < 20; i++) 'still the note $i',
        '*/',
        'let after = 1;',
      ].join('\n');
      await goTo(tester, text, 130, language: CodeLanguage.javascript);
      final brightness = Theme.of(tester.element(find.byType(DocumentView)))
          .brightness;
      // Row 129, in the second block, is inside the comment.
      expect(
        colourOf(tester, 'still the note 8'),
        tokenColor(TokenKind.comment, brightness),
      );
      expect(
        colourOf(tester, 'let after = 1;'),
        isNot(tokenColor(TokenKind.comment, brightness)),
      );
    });

    testWidgets('edits fetch again only what they change, and all of that', (
      tester,
    ) async {
      // Lines 0 to 199, so that rows 120 to 140, either side of where
      // the second block of rows starts, are on show around the caret.
      final document = MemoryDocument(
        [for (var i = 0; i < 200; i++) 'let line$i = $i;'].join('\n'),
      );
      final sought = ValueNotifier<int?>(null);
      addTearDown(sought.dispose);
      tester.view.physicalSize = const Size(900, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentView(
              name: 'doc',
              document: document,
              language: CodeLanguage.javascript,
              editable: true,
              lineSought: sought,
            ),
          ),
        ),
      );
      final brightness = Theme.of(tester.element(find.byType(DocumentView)))
          .brightness;
      final comment = tokenColor(TokenKind.comment, brightness);

      /// Every row on show is the document's row.
      void shownAsDocument() {
        final rows = document.rows(0, document.info().rowCount);
        var checked = 0;
        for (var i = 0; i < rows.length; i++) {
          final shown = find.byKey(ValueKey('doc-row-$i'));
          if (shown.evaluate().isEmpty) continue;
          final text = tester.widget<Text>(shown).textSpan!.toPlainText();
          expect(text, rows[i].text, reason: 'row $i');
          checked++;
        }
        expect(checked, greaterThan(10));
      }

      // The caret at the start of line 127, the last row of the first block.
      sought.value = 128;
      await tester.pump();
      await tester.pump();
      await key(tester, LogicalKeyboardKey.arrowLeft);
      shownAsDocument();

      // A new line moves every row after it down.
      await input(tester, '\n');
      await tester.pump();
      shownAsDocument();
      // Rubbing it out joins the lines again.
      await key(tester, LogicalKeyboardKey.backspace);
      shownAsDocument();

      // A comment opened here colours the rows after it, in the next block.
      await input(tester, '/*');
      await tester.pump();
      shownAsDocument();
      expect(colourOf(tester, 'let line130 = 130;'), comment);
      await press(tester, LogicalKeyboardKey.keyZ, modifier: control);
      shownAsDocument();
      expect(colourOf(tester, 'let line130 = 130;'), isNot(comment));
    });
  });
}
