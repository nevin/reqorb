import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:reqorb/document/json_scan.dart';
import 'package:reqorb/document/lex.dart' as lex;
import 'package:reqorb/document/text_document.dart';

/// A document held whole in Dart, which works as the Rust engine's does
/// in everything an editor can see: for widget tests, which run without
/// the engine. Each edit copies the text, so it is for small text only.
class MemoryDocument implements TextDocument {
  MemoryDocument(String text) : this.bytes(utf8.encode(text));

  /// A document of [bytes], which need not be UTF-8.
  MemoryDocument.bytes(Uint8List bytes) : _bytes = bytes {
    _relines();
  }

  /// Opens the file at [path], reading it whole.
  static Future<MemoryDocument> open(String path) async {
    final file = File(path);
    if (await FileSystemEntity.isDirectory(path)) throw '$path is a folder';
    final MemoryDocument document;
    try {
      document = MemoryDocument.bytes(await file.readAsBytes());
    } on FileSystemException catch (e) {
      throw '$path could not be opened: ${e.osError?.message ?? e.message}';
    }
    return document
      .._path = path
      .._stamp = document._stampOf(path);
  }

  /// Whether it is no longer to be used.
  bool disposed = false;

  Uint8List _bytes;

  /// Where each line starts, and each line's first row.
  List<int> _starts = const [0];
  List<int> _firstRows = const [0];
  int _rowCount = 1;

  final _undo = <_Step>[];
  final _redo = <_Step>[];
  int _nextId = 1;
  int? _saved;
  int _version = 0;
  String? _path;
  (int, DateTime)? _stamp;

  void _relines() {
    final starts = <int>[0];
    for (var i = 0; i < _bytes.length; i++) {
      if (_bytes[i] == 10) starts.add(i + 1);
    }
    _starts = starts;
    final firstRows = List<int>.filled(starts.length, 0);
    var rows = 0;
    for (var line = 0; line < starts.length; line++) {
      firstRows[line] = rows;
      rows += _parts(line);
    }
    _firstRows = firstRows;
    _rowCount = rows;
  }

  int get _lineCount => _starts.length;

  int _lineStart(int line) => _starts[line];

  int _lineEnd(int line) =>
      line + 1 < _starts.length ? _starts[line + 1] - 1 : _bytes.length;

  int _parts(int line) {
    final length = _lineEnd(line) - _lineStart(line);
    return math.max(1, (length + rowBytes - 1) ~/ rowBytes);
  }

  bool _continues(int at) => (_bytes[at] & 0xC0) == 0x80;

  int _partStart(int start, int end, int part) {
    if (part == 0) return start;
    var at = math.min(start + part * rowBytes, end);
    final stop = math.min(at + 3, end);
    while (at < stop && _continues(at)) {
      at++;
    }
    return at;
  }

  (int, int) _rowSpan(int line, int part) {
    final (ls, le) = (_lineStart(line), _lineEnd(line));
    final start = _partStart(ls, le, part);
    var end = part + 1 < _parts(line) ? _partStart(ls, le, part + 1) : le;
    if (end == le && end > start && _bytes[end - 1] == 13) end--;
    return (start, end);
  }

  (int, int) _lineOfRow(int row) {
    var low = 0;
    var high = _firstRows.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_firstRows[middle] <= row) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return (low, row - _firstRows[low]);
  }

  String _decode(int start, int end) =>
      utf8.decode(_bytes.sublist(start, end), allowMalformed: true);

  @override
  DocInfo info() => DocInfo(
    len: _bytes.length,
    lineCount: _lineCount,
    rowCount: _rowCount,
    version: _version,
    modified: (_undo.isEmpty ? null : _undo.last.id) != _saved,
    canUndo: _undo.isNotEmpty,
    canRedo: _redo.isNotEmpty,
    indexed: _bytes.length,
    indexingDone: true,
    path: _path,
  );

  @override
  bool get looksBinary =>
      _bytes.sublist(0, math.min(_bytes.length, 8192)).contains(0);

  @override
  List<DocRow> rows(int first, int count) {
    final rows = <DocRow>[];
    for (var row = first; row < _rowCount && rows.length < count; row++) {
      final (line, part) = _lineOfRow(row);
      final (start, end) = _rowSpan(line, part);
      rows.add(
        DocRow(
          line: line,
          segment: part,
          start: start,
          end: end,
          text: _decode(start, end),
          quoted: part > 0 && _quotedAt(_lineStart(line), start),
        ),
      );
    }
    return rows;
  }

  /// Whether a string in double quotes is open at [at], reading from
  /// [from], the start of its line.
  bool _quotedAt(int from, int at) {
    var open = false;
    var escaped = false;
    for (var i = from; i < at; i++) {
      final b = _bytes[i];
      if (escaped) {
        escaped = false;
      } else if (open && b == 0x5C) {
        escaped = true;
      } else if (b == 0x22) {
        open = !open;
      }
    }
    return open;
  }

  @override
  int lineOf(int offset) {
    final at = offset.clamp(0, _bytes.length);
    // The lines that start at or before it, less the first.
    var low = 0;
    var high = _starts.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_starts[middle] <= at) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  @override
  DocPosition positionOf(int offset) {
    final at = offset.clamp(0, _bytes.length);
    final line = lineOf(at);
    final (ls, le) = (_lineStart(line), _lineEnd(line));
    var part = math.min((at - ls) ~/ rowBytes, _parts(line) - 1);
    while (part > 0 && _partStart(ls, le, part) > at) {
      part--;
    }
    final (start, end) = _rowSpan(line, part);
    var k = math.min(at, end);
    while (k > start && k < end && _continues(k)) {
      k--;
    }
    return DocPosition(
      row: _firstRows[line] + part,
      col: _decode(start, k).length,
    );
  }

  @override
  int offsetOf(int row, int col) {
    final (line, part) = _lineOfRow(math.min(row, _rowCount - 1));
    final (start, end) = _rowSpan(line, part);
    var units = 0;
    var at = start;
    for (final rune in _decode(start, end).runes) {
      final width = rune > 0xFFFF ? 2 : 1;
      if (units + width > col) return at;
      units += width;
      at += utf8.encode(String.fromCharCode(rune)).length;
    }
    return at;
  }

  @override
  int rowOfLine(int line) => _firstRows[line.clamp(0, _lineCount - 1)];

  @override
  DocSpan lineSpan(int line) {
    if (line >= _lineCount) {
      return DocSpan(start: _bytes.length, end: _bytes.length);
    }
    return DocSpan(start: _lineStart(line), end: _lineEnd(line));
  }

  @override
  String text(int start, int end) {
    final from = start.clamp(0, _bytes.length);
    return _decode(from, end.clamp(from, _bytes.length));
  }

  void _splice(int at, int removed, Uint8List inserted) {
    _bytes = Uint8List.fromList([
      ..._bytes.sublist(0, at),
      ...inserted,
      ..._bytes.sublist(at + removed),
    ]);
    _relines();
    _version++;
  }

  @override
  void replace(int start, int end, String text, {bool typing = false}) {
    final length = _bytes.length;
    final from = start.clamp(0, length);
    final to = end.clamp(from, length);
    if (from == to && text.isEmpty) return;
    _redo.clear();
    final inserted = utf8.encode(text);
    final removed = _bytes.sublist(from, to);
    _splice(from, to - from, inserted);
    final last = _undo.isEmpty ? null : _undo.last;
    if (typing &&
        from == to &&
        !text.contains('\n') &&
        last != null &&
        last.id != _saved &&
        last.removed.isEmpty &&
        last.inserted.isNotEmpty &&
        !last.inserted.contains(10) &&
        last.at + last.inserted.length == from) {
      last
        ..inserted = Uint8List.fromList([...last.inserted, ...inserted])
        ..id = _nextId++;
      return;
    }
    _undo.add(_Step(_nextId++, from, removed, inserted));
  }

  @override
  Future<void> replaceAll(List<DocSpan> spans, String text) async {
    if (spans.isEmpty) return;
    _redo.clear();
    final before = _bytes;
    final replacement = utf8.encode(text);
    final out = BytesBuilder(copy: false);
    var at = 0;
    for (final span in spans) {
      final start = span.start.clamp(at, before.length);
      final end = span.end.clamp(start, before.length);
      out
        ..add(before.sublist(at, start))
        ..add(replacement);
      at = end;
    }
    out.add(before.sublist(at));
    final after = out.toBytes();
    _splice(0, before.length, after);
    _undo.add(_Step(_nextId++, 0, before, after));
  }

  @override
  DocSpan? undo() {
    if (_undo.isEmpty) return null;
    final step = _undo.removeLast();
    _splice(step.at, step.inserted.length, step.removed);
    _redo.add(step);
    return DocSpan(start: step.at, end: step.at + step.removed.length);
  }

  @override
  DocSpan? redo() {
    if (_redo.isEmpty) return null;
    final step = _redo.removeLast();
    _splice(step.at, step.removed.length, step.inserted);
    _undo.add(step);
    return DocSpan(start: step.at, end: step.at + step.inserted.length);
  }

  (int, DateTime)? _stampOf(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final stat = file.statSync();
    return (stat.size, stat.modified);
  }

  @override
  bool get changedOnDisk => _path != null && _stampOf(_path!) != _stamp;

  @override
  Future<void> save({String? path, bool force = false}) async {
    final target = path ?? _path;
    if (target == null) throw 'choose where to save the document';
    if (!force && target == _path && changedOnDisk) {
      throw '$target has been changed by another program since it was opened';
    }
    await File(target).writeAsBytes(_bytes, flush: true);
    _path = target;
    _stamp = _stampOf(target);
    _saved = _undo.isEmpty ? null : _undo.last.id;
  }

  @override
  Stream<DocSearchUpdate> search(DocQuery query) async* {
    if (query.text.isEmpty) {
      yield DocSearchUpdate(
        found: const [],
        searched: _bytes.length,
        done: true,
        count: 0,
      );
      return;
    }
    final RegExp pattern;
    try {
      var source = query.regex ? query.text : RegExp.escape(query.text);
      if (query.wholeWord) source = '\\b(?:$source)\\b';
      pattern = RegExp(
        source,
        caseSensitive: query.caseSensitive,
        multiLine: true,
        unicode: true,
      );
    } on FormatException catch (e) {
      yield DocSearchUpdate(
        found: const [],
        searched: 0,
        done: true,
        count: 0,
        error: 'the pattern is not valid: ${e.message}',
      );
      return;
    }
    final text = _decode(0, _bytes.length);
    final found = <DocSpan>[];
    var units = 0;
    var bytes = 0;
    int byteOf(int unit) {
      bytes += utf8.encode(text.substring(units, unit)).length;
      units = unit;
      return bytes;
    }

    for (final m in pattern.allMatches(text)) {
      if (m.start == m.end) continue;
      final start = byteOf(m.start);
      found.add(DocSpan(start: start, end: byteOf(m.end)));
    }
    yield DocSearchUpdate(
      found: found,
      searched: _bytes.length,
      done: false,
      count: 0,
    );
    yield DocSearchUpdate(
      found: const [],
      searched: _bytes.length,
      done: true,
      count: found.length,
    );
  }

  @override
  DocSpan? bracketPair(int at, DocQuoting quoting) {
    at = at.clamp(0, _bytes.length);
    final back = math.max(0, at - lex.lexReach);
    final from = _lineAfter(back, at) ?? back;
    final to = math.min(_bytes.length, at + lex.lexReach);
    final pair = lex.bracketPair(
      Uint8List.sublistView(_bytes, from, to),
      at - from,
      quoting,
    );
    return pair == null
        ? null
        : DocSpan(start: from + pair.$1, end: from + pair.$2);
  }

  @override
  String openerAt(int at, DocQuoting quoting) {
    at = at.clamp(0, _bytes.length);
    final from = _lineAfter(math.max(0, at - lex.lexReach), at);
    if (from == null) return '';
    return lex.openerAfter(Uint8List.sublistView(_bytes, from, at), quoting);
  }

  /// Where a scan back from [limit] to [from] starts: at [from] at the
  /// start of the text, otherwise where the next line starts, as the
  /// middle of a line may be the middle of a string; none if no line
  /// starts by [limit].
  int? _lineAfter(int from, int limit) {
    if (from == 0) return 0;
    final line = lineOf(from);
    final next = line + 1 < _lineCount ? _lineStart(line + 1) : _bytes.length;
    return next <= limit ? next : null;
  }

  @override
  Uint8List bytes(int start, int end) {
    final from = start.clamp(0, _bytes.length);
    return Uint8List.fromList(
      _bytes.sublist(from, end.clamp(from, _bytes.length)),
    );
  }

  @override
  Future<DocJsonNode> jsonRoot() async => jsonRootOf(_bytes);

  @override
  Future<DocJsonPage> jsonChildren(
    int at, {
    int? from,
    int count = 200,
  }) async => jsonChildrenOf(_bytes, at, from, count);

  @override
  Stream<DocFormatUpdate> formatJson({String? indent}) async* {
    final total = _bytes.length;
    try {
      final formatted = formatJsonBytes(_bytes, indent);
      final dir = await Directory.systemTemp.createTemp('reqorb_format');
      final file = File('${dir.path}/formatted.json');
      await file.writeAsBytes(formatted);
      yield DocFormatUpdate(
        read: total,
        total: total,
        done: true,
        path: file.path,
      );
    } on String catch (e) {
      yield DocFormatUpdate(read: 0, total: total, done: true, error: e);
    }
  }

  @override
  void dispose() => disposed = true;
}

class _Step {
  _Step(this.id, this.at, this.removed, this.inserted);

  int id;
  final int at;
  final Uint8List removed;
  Uint8List inserted;
}
