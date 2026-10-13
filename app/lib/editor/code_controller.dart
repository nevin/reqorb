import 'package:flutter/material.dart';
import 'package:reqorb/editor/syntax.dart';

/// A text controller that colours what it holds: the tokens of its
/// language, the bracket matching the one beside the caret, and whatever
/// a search has found.
class CodeController extends TextEditingController {
  CodeController({super.text, this.language});

  /// What the text is written in; null to go by how it looks. Set by
  /// whatever shows the controller, as it builds; the colours follow on
  /// the next build.
  CodeLanguage? language;

  /// The language the text is coloured as.
  CodeLanguage get shownAs => language ?? CodeLanguage.sniff(text);

  /// Where the current search matched, in order.
  List<TextRange> get found => _found;
  List<TextRange> _found = const [];

  /// Which of [found] the search is standing on; -1 for none.
  int get current => _current;
  int _current = -1;

  /// Shows what a search matched, and which match it is on.
  void mark(List<TextRange> found, int current) {
    _found = found;
    _current = current;
    notifyListeners();
  }

  /// Drops what a search marked without telling anyone, for when whatever
  /// showed the search has gone.
  void forgetMarks() {
    _found = const [];
    _current = -1;
  }

  String? _tokenized;
  CodeLanguage? _tokenizedAs;
  List<Token> _tokens = const [];

  /// The coloured stretches of the text, worked out once per edit.
  List<Token> get tokens {
    final text = this.text;
    final language = shownAs;
    if (!identical(text, _tokenized) || language != _tokenizedAs) {
      _tokenized = text;
      _tokenizedAs = language;
      _tokens = text.length > highlightLimit
          ? const []
          : tokenize(text, language);
    }
    return _tokens;
  }

  static const _open = '{[(';
  static const _close = '}])';

  /// How far to look for a bracket's partner before giving up.
  static const _reach = 50000;

  /// Whether [offset] is inside a string or a comment, where a bracket is
  /// only a character.
  bool _quoted(int offset) {
    final tokens = this.tokens;
    var low = 0, high = tokens.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final token = tokens[mid];
      if (offset < token.start) {
        high = mid - 1;
      } else if (offset >= token.end) {
        low = mid + 1;
      } else {
        return token.kind == TokenKind.string ||
            token.kind == TokenKind.comment ||
            token.kind == TokenKind.key;
      }
    }
    return false;
  }

  /// The bracket beside the caret and its partner, if both are there.
  (int, int)? matchingBrackets() {
    final selection = this.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final text = this.text;
    final caret = selection.baseOffset;
    // The one just typed, before the caret, comes first.
    for (final at in [caret - 1, caret]) {
      if (at < 0 || at >= text.length) continue;
      final char = text[at];
      final opens = _open.indexOf(char);
      final closes = _close.indexOf(char);
      if (opens < 0 && closes < 0) continue;
      if (_quoted(at)) continue;
      final forward = opens >= 0;
      final own = char.codeUnitAt(0);
      final other = (forward ? _close[opens] : _open[closes]).codeUnitAt(0);
      final step = forward ? 1 : -1;
      var depth = 0;
      for (
        var i = at, seen = 0;
        i >= 0 && i < text.length && seen < _reach;
        i += step, seen++
      ) {
        final unit = text.codeUnitAt(i);
        if (unit != own && unit != other) continue;
        if (_quoted(i)) continue;
        depth += unit == own ? 1 : -1;
        if (depth == 0) return forward ? (at, i) : (i, at);
      }
      return null;
    }
    return null;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final text = this.text;

    // Marks sit on top of the syntax colours. Kept in order and apart.
    final marks = <(int, int, TextStyle)>[];
    final foundStyle = TextStyle(
      backgroundColor: scheme.tertiary.withValues(alpha: 0.28),
    );
    final currentStyle = TextStyle(
      backgroundColor: scheme.tertiary.withValues(alpha: 0.7),
      color: scheme.onTertiary,
    );
    for (final (index, range) in _found.indexed) {
      if (range.end > text.length) break;
      marks.add((
        range.start,
        range.end,
        index == _current ? currentStyle : foundStyle,
      ));
    }
    if (matchingBrackets() case (final a, final b)) {
      final bracket = TextStyle(
        backgroundColor: scheme.primary.withValues(alpha: 0.25),
      );
      marks
        ..add((a, a + 1, bracket))
        ..add((b, b + 1, bracket));
    }
    final composing = value.composing;
    if (withComposing &&
        value.isComposingRangeValid &&
        !composing.isCollapsed) {
      marks.add((
        composing.start,
        composing.end,
        const TextStyle(decoration: TextDecoration.underline),
      ));
    }

    final tokens = this.tokens;
    if (tokens.isEmpty && marks.isEmpty) {
      return TextSpan(style: style, text: text);
    }
    if (marks.length > 1) marks.sort((a, b) => a.$1.compareTo(b.$1));

    final spans = <TextSpan>[];
    var m = 0;

    // Adds text[from..to] in one colour, split wherever a mark covers it.
    void add(int from, int to, TextStyle? colour) {
      var at = from;
      while (at < to) {
        // Marks that ended before here, or that an earlier one overlapped.
        while (m < marks.length && marks[m].$2 <= at) {
          m++;
        }
        if (m >= marks.length || marks[m].$1 >= to) {
          spans.add(TextSpan(text: text.substring(at, to), style: colour));
          return;
        }
        final (start, end, mark) = marks[m];
        if (start > at) {
          spans.add(TextSpan(text: text.substring(at, start), style: colour));
          at = start;
        }
        final until = end < to ? end : to;
        spans.add(
          TextSpan(
            text: text.substring(at, until),
            style: colour?.merge(mark) ?? mark,
          ),
        );
        at = until;
      }
    }

    var at = 0;
    for (final token in tokens) {
      if (token.start > at) add(at, token.start, null);
      add(
        token.start,
        token.end,
        TextStyle(color: tokenColor(token.kind, brightness)),
      );
      at = token.end;
    }
    if (at < text.length) add(at, text.length, null);
    return TextSpan(style: style, children: spans);
  }
}
