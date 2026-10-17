import 'dart:async';

import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/src/rust/api/document.dart' as rust;

/// A document held by the Rust engine, reached by its number.
class RustDocument implements TextDocument {
  RustDocument._(this._id);

  /// A document holding [text], not saved anywhere.
  factory RustDocument.of(String text) =>
      RustDocument._(rust.docFromText(text: text));

  /// Opens the file at [path]. Its start can be shown at once; its other
  /// lines are found in the background, as [info] tells.
  static Future<RustDocument> open(String path) async =>
      RustDocument._(await rust.docOpen(path: path));

  final int _id;
  bool _disposed = false;

  static int _searches = 0;

  @override
  DocInfo info() => rust.docInfo(id: _id);

  @override
  bool get looksBinary => rust.docLooksBinary(id: _id);

  @override
  List<DocRow> rows(int first, int count) =>
      rust.docRows(id: _id, first: first, count: count);

  @override
  DocPosition positionOf(int offset) =>
      rust.docPosition(id: _id, offset: offset);

  @override
  int offsetOf(int row, int col) => rust.docOffset(id: _id, row: row, col: col);

  @override
  int rowOfLine(int line) => rust.docRowOfLine(id: _id, line: line);

  @override
  DocSpan lineSpan(int line) => rust.docLineSpan(id: _id, line: line);

  @override
  int lineOf(int offset) => rust.docLineOf(id: _id, offset: offset);

  @override
  String text(int start, int end) =>
      rust.docText(id: _id, start: start, end: end);

  @override
  void replace(int start, int end, String text, {bool typing = false}) => rust
      .docReplace(id: _id, start: start, end: end, text: text, typing: typing);

  @override
  Future<void> replaceAll(List<DocSpan> spans, String text) =>
      rust.docReplaceAll(id: _id, spans: spans, text: text);

  @override
  DocSpan? undo() => rust.docUndo(id: _id);

  @override
  DocSpan? redo() => rust.docRedo(id: _id);

  @override
  bool get changedOnDisk => rust.docChangedOnDisk(id: _id);

  @override
  Future<void> save({String? path, bool force = false}) =>
      rust.docSave(id: _id, path: path, force: force);

  @override
  Stream<DocSearchUpdate> search(DocQuery query) {
    final search = ++_searches;
    late final StreamController<DocSearchUpdate> out;
    StreamSubscription<DocSearchUpdate>? from;
    out = StreamController(
      onListen: () {
        from = rust
            .docSearch(id: _id, search: search, query: query)
            .listen(out.add, onError: out.addError, onDone: out.close);
      },
      onCancel: () {
        rust.docCancelSearch(search: search);
        return from?.cancel();
      },
    );
    return out.stream;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    rust.docClose(id: _id);
  }
}
