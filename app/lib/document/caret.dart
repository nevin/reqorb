/// Moving through a [TextDocument] a character or a word at a time, and
/// converting between a string's UTF-16 units and its UTF-8 bytes, which
/// is what a document's positions count.
library;

import 'dart:math' as math;

import 'package:reqorb/document/text_document.dart';

/// How many bytes [text] takes as UTF-8, without encoding it.
int utf8Length(String text, [int start = 0, int? end]) {
  end ??= text.length;
  var bytes = 0;
  for (var i = start; i < end; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (_pairAt(text, i, end)) {
      // A pair of units, one character of four bytes.
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/// Whether a pair of surrogates, one character, starts at [i].
bool _pairAt(String text, int i, int end) {
  final unit = text.codeUnitAt(i);
  if (unit < 0xD800 || unit >= 0xDC00 || i + 1 >= end) return false;
  final next = text.codeUnitAt(i + 1);
  return next >= 0xDC00 && next < 0xE000;
}

/// The UTF-16 index in [text] that is [bytes] bytes into it as UTF-8. A
/// count of bytes inside a character gives the start of it.
int unitsOf(String text, int bytes) {
  var at = 0;
  var i = 0;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    final pair = _pairAt(text, i, text.length);
    final width = unit < 0x80
        ? 1
        : unit < 0x800
        ? 2
        : pair
        ? 4
        : 3;
    if (at + width > bytes) break;
    at += width;
    i += pair ? 2 : 1;
  }
  return i;
}

const _replacement = 0xFFFD;

/// The byte after the character at [offset]; a line break of `\r\n` is
/// one character. Bytes that are not UTF-8 are passed one at a time.
int nextChar(TextDocument doc, int offset) {
  final len = doc.info().len;
  if (offset >= len) return len;
  final text = doc.text(offset, math.min(len, offset + 4));
  if (text.startsWith('\r\n')) return offset + 2;
  final rune = text.runes.first;
  if (rune != _replacement) {
    return offset + utf8Length(String.fromCharCode(rune));
  }
  // A real U+FFFD, three bytes, reads as one; three bad bytes, as three.
  return offset +
      (doc.text(offset, math.min(len, offset + 3)) == '\uFFFD' ? 3 : 1);
}

/// The start of the character before [offset].
int previousChar(TextDocument doc, int offset) {
  if (offset <= 0) return 0;
  final text = doc.text(math.max(0, offset - 4), offset);
  if (text.endsWith('\r\n')) return offset - 2;
  final rune = text.runes.last;
  if (rune != _replacement) {
    return offset - utf8Length(String.fromCharCode(rune));
  }
  return offset -
      (offset >= 3 && doc.text(offset - 3, offset) == '\uFFFD' ? 3 : 1);
}

final _wordChar = RegExp(r'[\p{L}\p{N}_$]', unicode: true);

/// Whether [char] is part of a word, for moving and selecting by word.
bool isWordChar(String char) => _wordChar.hasMatch(char);

/// How far a word is looked for, either way: a word longer than this is
/// crossed in steps.
const _wordReach = 1024;

/// The end of the word at or after [offset], past anything between.
int nextWord(TextDocument doc, int offset) {
  final len = doc.info().len;
  final text = doc.text(offset, math.min(len, offset + _wordReach));
  var i = 0;
  while (i < text.length && !isWordChar(text[i])) {
    i++;
  }
  while (i < text.length && isWordChar(text[i])) {
    i++;
  }
  return math.min(len, offset + utf8Length(text, 0, i));
}

/// The start of the word at or before [offset], past anything between.
int previousWord(TextDocument doc, int offset) {
  final from = math.max(0, offset - _wordReach);
  final text = doc.text(from, offset);
  var i = text.length;
  while (i > 0 && !isWordChar(text[i - 1])) {
    i--;
  }
  while (i > 0 && isWordChar(text[i - 1])) {
    i--;
  }
  return math.max(0, offset - utf8Length(text, i));
}
