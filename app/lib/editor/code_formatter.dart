import 'package:flutter/services.dart';
import 'package:reqorb/shared/theme.dart';

const _pairs = {'{': '}', '[': ']', '(': ')', '"': '"'};

final _word = RegExp(r'[\w\\]');

/// What typing does beyond putting a character in: a new line keeps the
/// indentation of the one before, and brackets and quotes come in pairs.
/// Works on what was typed, so it is the same with any keyboard.
class CodeFormatter extends TextInputFormatter {
  CodeFormatter({required this.pairs});

  /// Whether brackets and quotes are closed as they are opened. Off for
  /// plain text, where a quote is as likely an apostrophe.
  final bool Function() pairs;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue old,
    TextEditingValue now,
  ) {
    // Text still being composed belongs to the input method.
    if (now.composing.isValid && !now.composing.isCollapsed) return now;
    if (!old.selection.isValid || !now.selection.isCollapsed) return now;
    final before = old.text;
    final after = now.text;
    final start = old.selection.start;
    final end = old.selection.end;
    final caret = now.selection.baseOffset;

    // One character typed where the selection was.
    if (after.length == before.length - (end - start) + 1 &&
        caret == start + 1 &&
        after.startsWith(before.substring(0, start)) &&
        after.endsWith(before.substring(end))) {
      final typed = after[start];
      if (typed == '\n') return _newLine(before, start, end);
      if (pairs()) return _pair(before, start, end, typed) ?? now;
      return now;
    }

    // One character rubbed out: an empty pair goes together.
    if (pairs() &&
        start == end &&
        start > 0 &&
        start < before.length &&
        caret == start - 1 &&
        after.length == before.length - 1 &&
        _pairs[before[start - 1]] == before[start] &&
        after == before.substring(0, start - 1) + before.substring(start)) {
      return TextEditingValue(
        text: before.substring(0, start - 1) + before.substring(start + 1),
        selection: TextSelection.collapsed(offset: start - 1),
      );
    }
    return now;
  }

  TextEditingValue _newLine(String text, int start, int end) {
    final lineStart = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    var indentEnd = lineStart;
    while (indentEnd < start &&
        (text[indentEnd] == ' ' || text[indentEnd] == '\t')) {
      indentEnd++;
    }
    final indent = text.substring(lineStart, indentEnd);
    var last = start - 1;
    while (last >= lineStart && text[last] == ' ') {
      last--;
    }
    final opener = last >= lineStart ? text[last] : '';
    final closer = opener == '"' ? null : _pairs[opener];
    var insert = '\n$indent';
    var tail = '';
    if (closer != null) {
      insert += CodeStyle.indent;
      // Between a pair, the closing one drops to a line of its own.
      if (end < text.length && text[end] == closer) tail = '\n$indent';
    }
    return TextEditingValue(
      text: text.substring(0, start) + insert + tail + text.substring(end),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
  }

  TextEditingValue? _pair(String text, int start, int end, String typed) {
    final next = end < text.length ? text[end] : '';
    // Typing a closing one that is already there steps over it.
    if (start == end && next == typed && _pairs.containsValue(typed)) {
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: start + 1),
      );
    }
    final closer = _pairs[typed];
    if (closer == null) return null;
    if (start != end) {
      // Around a selection, which stays selected.
      return TextEditingValue(
        text:
            text.substring(0, start) +
            typed +
            text.substring(start, end) +
            closer +
            text.substring(end),
        selection: TextSelection(baseOffset: start + 1, extentOffset: end + 1),
      );
    }
    // Only where the closing one would not run into what follows.
    if (next.isNotEmpty && !' \t\n)]},'.contains(next)) return null;
    if (typed == '"' && start > 0 && _word.hasMatch(text[start - 1])) {
      return null;
    }
    return TextEditingValue(
      text: text.substring(0, start) + typed + closer + text.substring(end),
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }
}
