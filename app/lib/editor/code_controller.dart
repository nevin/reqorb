import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:reqorb/editor/syntax.dart';

/// A text controller that colours what it holds: the tokens of its
/// language, the bracket matching the one beside the caret, and whatever
/// a search has found.
class CodeController extends TextEditingController {
  CodeController({super.text, this.language, this.onLink});

  /// Called with a web address in the text when it is clicked; null to
  /// leave addresses as text.
  final ValueChanged<Uri>? onLink;

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

  /// Asks whatever shows the text to select [line], counted from 1, and
  /// scroll it into view.
  void goToLine(int line) {
    final lines = text.split('\n');
    final index = (line - 1).clamp(0, lines.length - 1);
    var start = 0;
    for (var i = 0; i < index; i++) {
      start += lines[i].length + 1;
    }
    selection = TextSelection(
      baseOffset: start,
      extentOffset: start + lines[index].length,
    );
    // Through null, so that asking for the same line again is heard.
    _lineSought
      ..value = null
      ..value = start;
    _lineNumberSought
      ..value = null
      ..value = index + 1;
  }

  /// The offset [goToLine] last asked to be shown, for the editor.
  ValueListenable<int?> get lineSought => _lineSought;
  final _lineSought = ValueNotifier<int?>(null);

  /// The line [goToLine] last asked to be shown, counted from 1, for a
  /// [DocumentView], which counts in lines rather than characters.
  ValueListenable<int?> get lineNumberSought => _lineNumberSought;
  final _lineNumberSought = ValueNotifier<int?>(null);

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

  String? _linked;
  List<(int, int, TapGestureRecognizer)> _links = const [];

  /// The web addresses in the text, each with what opens it. Worked out
  /// once per text, as the tokens are.
  List<(int, int, TapGestureRecognizer)> get links {
    final text = this.text;
    final onLink = this.onLink;
    if (onLink == null || text.length > highlightLimit) return const [];
    if (!identical(text, _linked)) {
      _dropLinks();
      _linked = text;
      _links = [
        for (final match in _address.allMatches(text))
          if (Uri.tryParse(match[0]!) case final uri? when uri.host.isNotEmpty)
            (
              match.start,
              match.end,
              TapGestureRecognizer()..onTap = () => onLink(uri),
            ),
      ];
    }
    return _links;
  }

  /// An address up to a space or a quote, less the punctuation of the
  /// sentence or code around it.
  static final _address = RegExp(
    r'''https?://[^\s"'<>`\\]*[^\s"'<>`\\.,;:!?)\]}]''',
  );

  void _dropLinks() {
    for (final (_, _, recognizer) in _links) {
      recognizer.dispose();
    }
    _links = const [];
  }

  @override
  void dispose() {
    _dropLinks();
    _lineSought.dispose();
    _lineNumberSought.dispose();
    super.dispose();
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
    final links = this.links;
    if (tokens.isEmpty && marks.isEmpty && links.isEmpty) {
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
    return TextSpan(
      style: style,
      children: links.isEmpty ? spans : _withLinks(spans, links, scheme),
    );
  }

  /// [spans] split where the [links] begin and end, the links underlined
  /// and clickable.
  static List<TextSpan> _withLinks(
    List<TextSpan> spans,
    List<(int, int, TapGestureRecognizer)> links,
    ColorScheme scheme,
  ) {
    final out = <TextSpan>[];
    final linkStyle = TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary.withValues(alpha: 0.6),
    );
    var l = 0, offset = 0;
    for (final span in spans) {
      final text = span.text!;
      final end = offset + text.length;
      var at = offset;
      while (at < end) {
        while (l < links.length && links[l].$2 <= at) {
          l++;
        }
        if (l >= links.length || links[l].$1 >= end) {
          out.add(
            TextSpan(text: text.substring(at - offset), style: span.style),
          );
          break;
        }
        final (start, stop, recognizer) = links[l];
        if (start > at) {
          out.add(
            TextSpan(
              text: text.substring(at - offset, start - offset),
              style: span.style,
            ),
          );
          at = start;
        }
        final until = stop < end ? stop : end;
        out.add(
          TextSpan(
            text: text.substring(at - offset, until - offset),
            style: span.style?.merge(linkStyle) ?? linkStyle,
            recognizer: recognizer,
            mouseCursor: SystemMouseCursors.click,
          ),
        );
        at = until;
      }
      offset = end;
    }
    return out;
  }
}
