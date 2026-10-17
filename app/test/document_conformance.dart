/// What every [TextDocument] must do, whoever holds the text. Run against
/// [MemoryDocument] by `document_test.dart` and against the Rust engine's
/// documents by the end-to-end tests, so the two cannot drift apart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/document/text_document.dart';

typedef MakeDocument = Future<TextDocument> Function(String text);
typedef OpenDocument = Future<TextDocument> Function(String path);

/// Every row of [doc]'s text.
List<String> _rowTexts(TextDocument doc) => [
  for (final row in doc.rows(0, doc.info().rowCount)) row.text,
];

Future<List<DocSpan>> _find(TextDocument doc, DocQuery query) async {
  final found = <DocSpan>[];
  await for (final update in doc.search(query)) {
    if (update.error != null) throw update.error!;
    found.addAll(update.found);
    if (update.done) {
      expect(update.count, found.length);
      break;
    }
  }
  return found;
}

DocQuery _query(
  String text, {
  bool regex = false,
  bool caseSensitive = false,
  bool wholeWord = false,
}) => DocQuery(
  text: text,
  regex: regex,
  caseSensitive: caseSensitive,
  wholeWord: wholeWord,
);

void documentConformance(MakeDocument make, OpenDocument open) {
  final made = <TextDocument>[];
  Future<TextDocument> doc(String text) async {
    final document = await make(text);
    made.add(document);
    return document;
  }

  tearDown(() {
    for (final document in made) {
      document.dispose();
    }
    made.clear();
  });

  test('an empty document has one empty row', () async {
    final d = await doc('');
    final info = d.info();
    expect((info.len, info.lineCount, info.rowCount), (0, 1, 1));
    expect(_rowTexts(d), ['']);
    expect(d.positionOf(0), DocPosition(row: 0, col: 0));
    expect(d.offsetOf(5, 5), 0);
  });

  test('shows lines as rows, without their line breaks', () async {
    final d = await doc('one\r\ntwo\n\nlast');
    expect(_rowTexts(d), ['one', 'two', '', 'last']);
    final rows = d.rows(1, 2);
    expect(rows.map((r) => (r.line, r.segment, r.start, r.end)), [
      (1, 0, 5, 8),
      (2, 0, 9, 9),
    ]);
    expect(d.lineSpan(0), DocSpan(start: 0, end: 4));
    expect(d.lineOf(6), 1);
    expect(d.lineOf(99), 3);
    expect(d.rowOfLine(3), 3);
    expect(d.text(5, 8), 'two');
  });

  test('a long line goes on over rows split between characters', () async {
    // Two bytes a character, so every split falls inside one unless moved.
    final line = 'é' * 3000;
    final d = await doc('a\n$line\nb');
    final info = d.info();
    expect((info.lineCount, info.rowCount), (3, 5));
    final rows = d.rows(0, 10);
    expect(rows.map((r) => (r.line, r.segment)), [
      (0, 0),
      (1, 0),
      (1, 1),
      (1, 2),
      (2, 0),
    ]);
    expect(rows.sublist(1, 4).map((r) => r.text).join(), line);
    expect(d.rowOfLine(2), 4);
    // Columns count UTF-16 units: one for each é.
    final middle = 2 + 2 * 1500;
    expect(d.positionOf(middle), DocPosition(row: 2, col: 1500 - 1024));
    expect(d.offsetOf(2, 1500 - 1024), middle);
    expect(d.positionOf(middle + 1), DocPosition(row: 2, col: 1500 - 1024));
  });

  test('columns count UTF-16 units', () async {
    final d = await doc('a😀b\nx');
    expect(d.positionOf(5), DocPosition(row: 0, col: 3));
    expect(d.offsetOf(0, 3), 5);
    expect(d.offsetOf(0, 2), 1, reason: 'inside a pair, back to its start');
    expect(d.offsetOf(0, 99), 6);
    expect(d.offsetOf(9, 0), 7, reason: 'past the last row, the last row');
  });

  test('edits, and undoes typing a run at a time', () async {
    final d = await doc('ab');
    expect(d.info().modified, isFalse);
    for (final (i, c) in 'cde'.split('').indexed) {
      d.replace(2 + i, 2 + i, c, typing: true);
    }
    d.replace(1, 1, 'X', typing: true);
    d.replace(2, 2, 'Y', typing: true);
    expect(d.text(0, 99), 'aXYbcde');
    var info = d.info();
    expect((info.modified, info.canUndo, info.canRedo), (true, true, false));
    final version = info.version;

    expect(d.undo(), DocSpan(start: 1, end: 1));
    expect(d.text(0, 99), 'abcde');
    expect(d.info().version, isNot(version));
    expect(d.undo(), DocSpan(start: 2, end: 2));
    expect(d.text(0, 99), 'ab');
    info = d.info();
    expect((info.modified, info.canUndo, info.canRedo), (false, false, true));
    expect(d.undo(), isNull);
    expect(d.redo(), DocSpan(start: 2, end: 5));
    expect(d.text(0, 99), 'abcde');

    d.replace(0, 5, 'one\ntwo');
    expect(d.info().lineCount, 2);
    expect(
      d.info().canRedo,
      isFalse,
      reason: 'an edit forgets what was undone',
    );
    d.replace(99, 99, '!');
    expect(d.text(0, 99), 'one\ntwo!');
  });

  test('replace all is one step', () async {
    final d = await doc('a-b-c\nd-e');
    final found = await _find(d, _query('-', caseSensitive: true));
    expect(found.length, 3);
    await d.replaceAll(found, '\n');
    expect(d.text(0, 99), 'a\nb\nc\nd\ne');
    expect(d.info().lineCount, 5);
    expect(d.undo(), DocSpan(start: 0, end: 9));
    expect(d.text(0, 99), 'a-b-c\nd-e');
    d.redo();
    expect(_rowTexts(d), ['a', 'b', 'c', 'd', 'e']);
  });

  test('finds text and patterns', () async {
    final d = await doc('Cat cat concat\ncat-food CAT é');
    List<(int, int)> spans(List<DocSpan> found) => [
      for (final s in found) (s.start, s.end),
    ];
    expect(spans(await _find(d, _query('cat', caseSensitive: true))), [
      (4, 7),
      (11, 14),
      (15, 18),
    ]);
    expect((await _find(d, _query('cat'))).length, 5);
    expect(spans(await _find(d, _query('cat', wholeWord: true))), [
      (0, 3),
      (4, 7),
      (15, 18),
      (24, 27),
    ]);
    expect(
      spans(
        await _find(d, _query(r'^cat\S*', regex: true, caseSensitive: true)),
      ),
      [(15, 23)],
    );
    // Matches after a character of two bytes are placed in bytes.
    expect(spans(await _find(d, _query('é'))), [(28, 30)]);
    expect(await _find(d, _query('')), isEmpty);
    await expectLater(_find(d, _query('(', regex: true)), throwsA(anything));
  });

  test('saves, notices changes on disk, and saves elsewhere', () async {
    final dir = await Directory.systemTemp.createTemp('reqorb_doc');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/notes.txt';
    await File(path).writeAsString('one\ntwo\n');

    final d = await open(path);
    made.add(d);
    expect(d.info().path, path);
    expect(_rowTexts(d), ['one', 'two', '']);
    d.replace(4, 7, 'TWO');
    expect(d.info().modified, isTrue);
    await d.save();
    expect(d.info().modified, isFalse);
    expect(await File(path).readAsString(), 'one\nTWO\n');
    expect(d.changedOnDisk, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File(path).writeAsString('changed elsewhere, and longer');
    expect(d.changedOnDisk, isTrue);
    d.replace(0, 0, 'zero\n');
    await expectLater(d.save(), throwsA(anything));
    await d.save(force: true);
    expect(await File(path).readAsString(), 'zero\none\nTWO\n');

    final copy = '${dir.path}/copy.txt';
    await d.save(path: copy);
    expect(d.info().path, copy);
    expect(await File(copy).readAsString(), 'zero\none\nTWO\n');
  });

  test('a document from text needs somewhere to save', () async {
    final d = await doc('x');
    await expectLater(d.save(), throwsA(anything));
  });

  test('tells binary from text', () async {
    final dir = await Directory.systemTemp.createTemp('reqorb_doc');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/image.png';
    await File(path).writeAsBytes([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 13]);
    final d = await open(path);
    made.add(d);
    expect(d.looksBinary, isTrue);
    expect((await doc('plain')).looksBinary, isFalse);
  });

  test('edits at random keep rows and text in step', () async {
    var model = '{\n  "name": "reqorb",\r\n  "tags": ["a", "b"]\n}\nlast é 日本';
    final d = await doc(model);
    var seed = 7;
    int next(int n) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return n == 0 ? 0 : seed % n;
    }

    const parts = ['a', '\n', '\r\n', 'é', '😀', '{"k": 1}', ' '];
    for (var step = 0; step < 150; step++) {
      final bytes = utf8.encode(model);
      // Keep to whole characters, as an editor does.
      final boundaries = <int>[0];
      var at = 0;
      for (final rune in model.runes) {
        at += utf8.encode(String.fromCharCode(rune)).length;
        boundaries.add(at);
      }
      final a = boundaries[next(boundaries.length)];
      final b = boundaries.firstWhere(
        (x) => x >= a + next(20),
        orElse: () => bytes.length,
      );
      var text = [for (var i = next(5); i > 0; i--) parts[next(parts.length)]]
          .join();
      if (next(15) == 0) text += 'x' * (rowBytes + next(3000));
      model = utf8.decode([
        ...bytes.sublist(0, a),
        ...utf8.encode(text),
        ...bytes.sublist(b),
      ]);
      d.replace(a, b, text, typing: next(2) == 0);
      expect(d.text(0, 1 << 30), model, reason: 'step $step');
      final lines = model.split('\n');
      expect(d.info().lineCount, lines.length);
      // The rows of each line, put together, are the line.
      final shown = <int, StringBuffer>{};
      for (final row in d.rows(0, d.info().rowCount)) {
        (shown[row.line] ??= StringBuffer()).write(row.text);
      }
      for (final (i, line) in lines.indexed) {
        final expected = line.endsWith('\r')
            ? line.substring(0, line.length - 1)
            : line;
        expect(shown[i]?.toString() ?? '', expected, reason: 'line $i');
      }
    }
  });
}
