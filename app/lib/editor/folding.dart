import 'package:reqorb/editor/syntax.dart';

/// A stretch of code that can be folded away: from the bracket at [open],
/// on line [line], to its partner at [close] on a later line.
class FoldRegion {
  const FoldRegion(this.open, this.close, this.line);

  final int open;
  final int close;

  /// The line the region opens on, counted from 1.
  final int line;
}

/// Code with some of its regions folded, and how its lines relate to the
/// lines of the whole.
class FoldedText {
  const FoldedText(this.text, this.numbers, this.folds, this.opens);

  /// What is shown: the code, with `…` in place of what is folded.
  final String text;

  /// The number each shown line has in the whole code.
  final List<int> numbers;

  /// For each shown line: null if nothing folds there, otherwise whether
  /// it is folded.
  final List<bool?> folds;

  /// For each shown line, where the region that folds there opens; -1
  /// for none.
  final List<int> opens;
}

/// Whether the regions of code in [language] are found by its brackets.
bool folds(CodeLanguage language) =>
    language == CodeLanguage.json ||
    language == CodeLanguage.graphql ||
    language == CodeLanguage.javascript;

/// The regions of [text] that span lines, outermost first. At most one
/// opens on any line. [tokens] say where the strings and comments are,
/// whose brackets do not count.
List<FoldRegion> foldRegions(String text, List<Token> tokens) {
  const openers = '{[(';
  const closers = '}])';
  final regions = <FoldRegion>[];
  final stack = <(int, int, int)>[];
  var line = 1;
  var t = 0;
  for (var i = 0; i < text.length; i++) {
    while (t < tokens.length && tokens[t].end <= i) {
      t++;
    }
    final char = text[i];
    if (char == '\n') {
      line++;
      continue;
    }
    if (t < tokens.length && tokens[t].start <= i) {
      final kind = tokens[t].kind;
      if (kind == TokenKind.string ||
          kind == TokenKind.comment ||
          kind == TokenKind.key) {
        continue;
      }
    }
    final opens = openers.indexOf(char);
    if (opens >= 0) {
      stack.add((opens, i, line));
      continue;
    }
    final closes = closers.indexOf(char);
    if (closes < 0 || stack.isEmpty) continue;
    final (kind, at, openedOn) = stack.last;
    // A bracket with no partner; leave the rest unfolded around it.
    if (kind != closes) continue;
    stack.removeLast();
    if (openedOn < line) regions.add(FoldRegion(at, i, openedOn));
  }
  regions.sort((a, b) => a.open.compareTo(b.open));
  final first = <FoldRegion>[];
  for (final region in regions) {
    if (first.isEmpty || first.last.line != region.line) first.add(region);
  }
  return first;
}

/// [source] with the [regions] that open at one of [folded] folded away.
FoldedText foldText(String source, List<FoldRegion> regions, Set<int> folded) {
  final byLine = {for (final region in regions) region.line: region};
  final shown = StringBuffer();
  final numbers = <int>[1];
  var line = 1;
  var at = 0;

  void copy(int to) {
    for (var i = at; i < to; i++) {
      if (source.codeUnitAt(i) == 0x0A) numbers.add(++line);
    }
    shown.write(source.substring(at, to));
    at = to;
  }

  for (final region in regions) {
    // Inside one already folded.
    if (region.open < at || !folded.contains(region.open)) continue;
    copy(region.open + 1);
    shown.write('…');
    for (var i = at; i < region.close; i++) {
      if (source.codeUnitAt(i) == 0x0A) line++;
    }
    at = region.close;
  }
  copy(source.length);

  return FoldedText(
    shown.toString(),
    numbers,
    [
      for (final number in numbers)
        byLine.containsKey(number)
            ? folded.contains(byLine[number]!.open)
            : null,
    ],
    [for (final number in numbers) byLine[number]?.open ?? -1],
  );
}
