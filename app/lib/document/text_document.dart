/// Text of any size for the editor, up to about a gigabyte: what it holds,
/// how it is shown in rows, and changing, undoing, searching and saving it.
library;

import 'dart:typed_data';

import 'package:reqorb/src/rust/api/document.dart';

export 'package:reqorb/src/rust/api/document.dart'
    show
        DocFormatUpdate,
        DocInfo,
        DocJsonKind,
        DocJsonNode,
        DocJsonPage,
        DocPosition,
        DocQuery,
        DocQuoting,
        DocRow,
        DocSearchUpdate,
        DocSpan;

/// The most bytes of a line shown in one row. Longer lines go on over
/// several rows, so that a megabyte of JSON on one line can be shown.
const rowBytes = 2048;

/// A document, held by the Rust engine ([Engine.openDocument]) or, in
/// tests, in Dart. Positions are byte offsets into its UTF-8 text; within
/// a row, columns are counted in UTF-16 units, as Dart strings are.
abstract class TextDocument {
  /// How big it is and how far along, taking in any lines found in the
  /// background since last asked. Cheap enough to ask on every frame.
  DocInfo info();

  /// Whether its start holds a NUL, as binary files do and text never does.
  bool get looksBinary;

  /// Up to [count] rows from row [first].
  List<DocRow> rows(int first, int count);

  /// The row and column byte [offset] is shown at.
  DocPosition positionOf(int offset);

  /// The byte shown at column [col] of row [row]; the end of the row for
  /// a column past it.
  int offsetOf(int row, int col);

  /// The first row of [line], counted from 0.
  int rowOfLine(int line);

  /// Where [line] starts and ends, before its line break.
  DocSpan lineSpan(int line);

  /// The line byte [offset] is on.
  int lineOf(int offset);

  /// Bytes [start] to [end] as text.
  String text(int start, int end);

  /// The bracket just before byte [at], or at it, and its partner, the
  /// opening one first, when neither is in a string or a comment of a
  /// language quoted as [quoting] says, and both are within 64 KB of [at].
  /// Only brackets of its own kind are counted.
  DocSpan? bracketPair(int at, DocQuoting quoting);

  /// What, put before the text from byte [at], has it coloured as it
  /// would be with all that comes before: the opening of the string or
  /// comment [at] is inside, as far as 64 KB back tells. Empty in code.
  String openerAt(int at, DocQuoting quoting);

  /// Bytes [start] to [end] as they are, for showing in hexadecimal.
  Uint8List bytes(int start, int end);

  /// The JSON value at the top of the text. Reads all of it, to find
  /// where it ends; throws if it is not JSON.
  Future<DocJsonNode> jsonRoot();

  /// Up to [count] children of the JSON object or array at byte [at]:
  /// from its first, or from [from], where a page before left off. Reads
  /// only as much as they take up.
  Future<DocJsonPage> jsonChildren(int at, {int? from, int count = 200});

  /// Writes the text, which is JSON, to a new temporary file: indented by
  /// [indent], or minified without one. Reports how far it has read, and
  /// at the end the file, or why it could not; cancelling stops it.
  Stream<DocFormatUpdate> formatJson({String? indent});

  /// Puts [text] in place of bytes [start] to [end]. With [typing], text
  /// that carries straight on from the last edit joins it as one step of
  /// undo.
  void replace(int start, int end, String text, {bool typing = false});

  /// Puts [text] in place of every one of [spans], which are in order and
  /// do not overlap, as one step of undo.
  Future<void> replaceAll(List<DocSpan> spans, String text);

  /// Undoes the last edit, giving the bytes it changed.
  DocSpan? undo();

  /// Does the last edit undone again, giving the bytes it changed.
  DocSpan? redo();

  /// Whether the file has been changed by something else since it was
  /// opened or saved.
  bool get changedOnDisk;

  /// Saves to [path], or to the file it came from. Saving over a file
  /// something else has changed fails unless [force] is set.
  Future<void> save({String? path, bool force = false});

  /// Finds [query], reporting matches as they are found. Cancelling the
  /// subscription stops the search.
  Stream<DocSearchUpdate> search(DocQuery query);

  /// Lets go of it. Nothing may be asked of it after.
  void dispose();
}
