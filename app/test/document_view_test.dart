import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/document/memory_document.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/document_view.dart';

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

  Future<void> show(
    WidgetTester tester,
    TextDocument document, {
    ValueListenable<int?>? lineSought,
  }) async {
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

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();
  }

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
}
