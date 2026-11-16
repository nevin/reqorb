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
    expect(rows.map((r) => r.quoted), everyElement(isFalse));
    // A string through a split: the row after begins inside it.
    final quoted = await doc(
      '["${'x' * 3000}\\"", "${'y' * 500}", ${'2, ' * 300}0]',
    );
    expect(quoted.rows(0, 9).map((r) => r.quoted), [false, true, false]);
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

  test('gives bytes as they are', () async {
    final dir = await Directory.systemTemp.createTemp('reqorb_doc');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/data.bin';
    await File(path).writeAsBytes([0, 1, 0xff, 0x80, 65]);
    final d = await open(path);
    made.add(d);
    expect(d.bytes(1, 4), [1, 0xff, 0x80]);
    expect(d.bytes(3, 99), [0x80, 65]);
    expect(d.bytes(9, 12), isEmpty);
  });

  test('lists the children of JSON a page at a time', () async {
    final d = await doc(
      '﻿{"name": "re\\"qorb", "n": -1.5e3, "ok": true, "none": null,\n '
      '"list": [1, [2, "]"], {"a": {}}], "é": "日本"}',
    );
    final root = await d.jsonRoot();
    expect(
      (root.kind, root.start, root.end),
      (DocJsonKind.object, 3, d.info().len),
    );
    final page = await d.jsonChildren(root.start, count: 3);
    expect(page.nodes.map((n) => n.key), ['name', 'n', 'ok']);
    expect(page.nodes.map((n) => n.preview), ['re\\"qorb', '-1.5e3', 'true']);
    final rest = await d.jsonChildren(root.start, from: page.next);
    expect(rest.next, isNull);
    expect(rest.nodes.map((n) => n.kind), [
      DocJsonKind.null_,
      DocJsonKind.array,
      DocJsonKind.string,
    ]);
    expect((rest.nodes[2].key, rest.nodes[2].preview), ('é', '日本'));
    final items = await d.jsonChildren(rest.nodes[1].start);
    expect(items.nodes.map((n) => d.text(n.start, n.end)), [
      '1',
      '[2, "]"]',
      '{"a": {}}',
    ]);
    await expectLater(d.jsonChildren(1), throwsA(anything));
    final broken = await doc('{\n  "a": 1,\n  "b" 2\n}');
    await expectLater(
      broken.jsonChildren(0),
      throwsA(predicate((e) => '$e'.contains('line 3'))),
    );
  });

  test('writes JSON out again indented or minified', () async {
    Future<String> formatted(TextDocument d, String? indent) async {
      final last = await d.formatJson(indent: indent).last;
      if (last.error != null) throw last.error!;
      expect(last.read, last.total);
      return File(last.path!).readAsString();
    }

    final d = await doc(
      '{"a":[1,2,{}],"s":"x , : { [\\" y",\n\n  "e" : [ ] , "t":true}',
    );
    expect(
      await formatted(d, '  '),
      '{\n  "a": [\n    1,\n    2,\n    {}\n  ],\n  "s": "x , : { [\\" y",\n'
      '  "e": [],\n  "t": true\n}\n',
    );
    expect(
      await formatted(d, null),
      '{"a":[1,2,{}],"s":"x , : { [\\" y","e":[],"t":true}',
    );
    expect(
      await formatted(await doc('{"a": 1}\n{"b": 2}\n3 4'), null),
      '{"a":1}\n{"b":2}\n3\n4',
    );
    await expectLater(
      formatted(await doc('[1, 2}'), '  '),
      throwsA(predicate((e) => '$e'.contains('does not match'))),
    );
  });

  test('pairs brackets outside strings and comments', () async {
    Future<(int, int)?> pair(String text, int at, DocQuoting q) async {
      final span = (await doc(text)).bracketPair(at, q);
      return span == null ? null : (span.start, span.end);
    }

    const json = '{\n  "a": [1, {"b": "}"}],\n  "c": 3\n}';
    expect(await pair(json, 1, DocQuoting.json), (0, json.length - 1));
    expect(await pair(json, json.length - 1, DocQuoting.json), (
      0,
      json.length - 1,
    ));
    // Next to no bracket, or next to one in a string.
    expect(await pair(json, 4, DocQuoting.json), isNull);
    expect(await pair(json, json.indexOf('}"'), DocQuoting.json), isNull);
    // The one just typed, before the caret, comes first.
    expect(await pair('f(x)()', 5, DocQuoting.javaScript), (4, 5));
    // Only brackets of its own kind are counted.
    expect(await pair('{[}', 1, DocQuoting.json), (0, 2));
    expect(await pair('{[}', 2, DocQuoting.json), isNull);

    const js = "f(/* ) */ ')', `\n)`, // )\n x)";
    expect(await pair(js, 1, DocQuoting.javaScript), (1, js.length - 1));
    const script = "f( '\n)' \\' # )\n)";
    expect(await pair(script, 1, DocQuoting.script), (1, script.length - 1));
    const graphql = 'q( """\n)""" "(" # (\n)';
    expect(await pair(graphql, 1, DocQuoting.graphql), (1, graphql.length - 1));
    const xml = '<a b=")"> ( <!-- ) --> <![CDATA[ ) ]]> )';
    final open = xml.indexOf('( ');
    expect(await pair(xml, open, DocQuoting.xml), (open, xml.length - 1));

    // Further apart than 64 KB, the two are not paired.
    final filler = '${'x' * 99}\n' * 1000;
    expect(await pair('{\n$filler}', 1, DocQuoting.json), isNull);
    final near = await pair('$filler(a)', filler.length + 1, DocQuoting.json);
    expect(near, (filler.length, filler.length + 2));
  });

  test('tells what a place is inside, for colouring from it', () async {
    Future<String> opener(String text, String at, DocQuoting q) async {
      final offset = utf8.encode(text.substring(0, text.indexOf(at))).length;
      return (await doc(text)).openerAt(offset, q);
    }

    const js = 'a\n/* one\ntwo\n*/ three\n`x é\ny';
    expect(await opener(js, 'two', DocQuoting.javaScript), '/*');
    expect(await opener(js, 'three', DocQuoting.javaScript), '');
    expect(await opener(js, 'y', DocQuoting.javaScript), '`');
    expect(await opener(js, 'a', DocQuoting.javaScript), '');
    expect(await opener("x 'a\nb", 'b', DocQuoting.script), "'");
    expect(await opener('"""a\nb', 'b', DocQuoting.graphql), '"""');
    expect(await opener('<a\n  b="1\n2', '2', DocQuoting.xml), '<a b="');
    expect(await opener('<a\n  b=1', 'b=', DocQuoting.xml), '<a ');
    expect(await opener('<!-- a\nb', 'b', DocQuoting.xml), '<!--');
    // A string on one line ends with it.
    expect(await opener('"a\nb', 'b', DocQuoting.json), '');
    // Further back than 64 KB, nothing is known.
    final long = '/*${'x' * (70 * 1024)}\nend';
    expect(await opener(long, 'end', DocQuoting.javaScript), '');
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
