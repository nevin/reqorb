import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/document/caret.dart';
import 'package:reqorb/document/memory_document.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/response/response_view.dart' show formatSize;
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/shared/theme.dart';

/// The longest text, in characters, shown in an editor; longer text is
/// shown in a [DocumentView]. An editor lays out all its text again on
/// each change: at a megabyte that takes half a second, and at ten, ten
/// seconds or more.
const editLimit = 1024 * 1024;

/// The most text copied at once. Past this the clipboard, and whatever it
/// is pasted into, would struggle.
const copyLimit = 64 * 1024 * 1024;

/// Rows fetched from the document at once.
const _block = 128;

/// Space above and below the rows.
const _padding = 8.0;

/// The most lines indented or outdented at once.
const _indentLimit = 100000;

/// Text of any size, shown a screenful at a time: coloured, numbered,
/// selectable with the mouse, copied and searched, and, when [editable],
/// typed into. Only the rows in view are asked of the document, so a
/// gigabyte opens as fast as a line.
///
/// Typing goes through the platform's input method, so accents and
/// Chinese or Japanese input work. It is told only the rows around the
/// selection, never the whole text.
///
/// The rows are keyed `<name>`; each row's text `<name>-row-<row>`; the
/// numbers beside them `<name>-number-<row>`; the status line `<name>-status`; the find bar's
/// parts `<name>-find`, `<name>-find-field`, `<name>-find-count`,
/// `<name>-find-next`, `<name>-find-previous`, `<name>-find-close`,
/// `<name>-find-case`, `<name>-find-regex` and `<name>-find-word`; and
/// replacing's `<name>-replace-toggle`, `<name>-replace-field`,
/// `<name>-replace-one` and `<name>-replace-all`.
class DocumentView extends StatefulWidget {
  const DocumentView({
    super.key,
    required this.document,
    this.name = 'document',
    this.language,
    this.lineSought,
    this.editable = false,
    this.status = false,
    this.autofocus = false,
    this.onChanged,
    this.onLink,
    this.spanSought,
  });

  /// What is shown. Whoever made it disposes of it.
  final TextDocument document;
  final String name;

  /// What the text is written in; null to go by how it starts.
  final CodeLanguage? language;

  /// A line to select and bring into view, counted from 1. Asking for the
  /// same line again goes through null.
  final ValueListenable<int?>? lineSought;

  /// Whether the text can be changed.
  final bool editable;

  /// Whether a line along the bottom shows where the caret is, what is
  /// selected, and how big the document is.
  final bool status;

  final bool autofocus;

  /// Called after each edit, undo and redo.
  final VoidCallback? onChanged;

  /// Opens a web address in the text, clicked with Command (Control
  /// elsewhere); null to leave addresses as text.
  final ValueChanged<Uri>? onLink;

  /// Bytes to select and bring into view, as when a value is picked in a
  /// tree of the same text. Asking for the same again goes through null.
  final ValueListenable<DocSpan?>? spanSought;

  @override
  State<DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends State<DocumentView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  /// The line numbers' own list, kept where the text's is.
  final _numbers = ScrollController();
  final _focus = FocusNode(debugLabel: 'document');
  final _query = TextEditingController();
  final _queryFocus = FocusNode(debugLabel: 'document find');
  final _replacement = TextEditingController();
  final _replaceFocus = FocusNode(debugLabel: 'document replace');

  /// The rows' area, which the input method is told the place of.
  final _viewKey = GlobalKey();

  late DocInfo _info;
  late CodeLanguage _language;

  /// Asks after the lines still being found, until they all are.
  Timer? _indexing;

  /// Rows fetched, by block, and their colours, for the version of the
  /// document they were fetched at.
  final _blocks = <int, List<DocRow>>{};
  final _spans = <int, List<TextSpan>>{};
  int _cachedVersion = -1;
  Brightness? _cachedBrightness;

  /// The most characters in any row fetched, which sets how far the text
  /// scrolls across.
  int _widest = 0;

  /// What is selected, as bytes: where it was started and where it is
  /// now. Its ends as shown, in order, worked out when it changes.
  int? _anchor;
  int? _extent;
  DocPosition? _from;
  DocPosition? _to;

  /// Where the caret, the selection's moving end, is shown.
  DocPosition? _caret;

  /// How far across up and down aim for while they go on being pressed,
  /// so that a short row on the way does not pull the caret to the left.
  double? _goalX;

  /// The input method's connection, while the text has the focus and can
  /// be edited.
  TextInputConnection? _input;
  late final _client = _InputClient(this);

  /// What the input method was last told: the rows around the selection.
  /// Its text stands for the bytes from [_windowStart]; or, when
  /// [_windowWhole] is false, is empty and stands for the whole selection,
  /// [_windowStart] to [_windowEnd], too big to tell.
  TextEditingValue _sent = TextEditingValue.empty;
  int _windowStart = 0;
  int _windowEnd = 0;
  bool _windowWhole = true;

  /// What the input method is composing, as bytes, while it is.
  (int, int)? _composing;

  /// The bracket beside the caret and its partner, as bytes, if both are
  /// there.
  (int, int)? _brackets;

  /// Whether the selection was made by touch, which shows handles to
  /// change it.
  bool _byTouch = false;

  /// The menu of Cut, Copy, Paste and Select All: shown over the
  /// selection, or at a point in the view; none while it is hidden.
  bool _menuOverSelection = false;
  Offset? _menuAt;

  /// The line a screen reader was last told the caret is on.
  int? _announced;

  /// The word a long press selected, which dragging on from it extends.
  (int, int)? _pressedWord;

  /// For telling a double or triple click from separate ones.
  DateTime _lastDown = DateTime(0);
  Offset _lastDownAt = Offset.zero;
  int _clicks = 0;

  bool _finding = false;
  bool _replacing = false;
  bool _caseSensitive = false;
  bool _regex = false;
  bool _wholeWord = false;
  List<DocSpan> _found = const [];
  int _count = 0;
  int _current = -1;
  bool _searching = false;
  String? _searchError;
  StreamSubscription<DocSearchUpdate>? _search;
  Timer? _searchSoon;

  TextDocument get _doc => widget.document;

  bool get _apple =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _open();
    widget.lineSought?.addListener(_goToLine);
    widget.spanSought?.addListener(_goToSpan);
    // Asked for before this view was made, as when it takes over from a
    // tree: shown once it is laid out.
    if (widget.spanSought?.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _goToSpan();
      });
    }
    _focus.addListener(_focusChanged);
    // Handles and the menu move with the text.
    _vertical.addListener(_scrolled);
    _horizontal.addListener(_scrolled);
  }

  void _scrolled() {
    _followText();
    if (_byTouch || _menuOverSelection) setState(() {});
  }

  /// Scrolls the line numbers to where the text is.
  void _followText() {
    if (!_numbers.hasClients || !_vertical.hasClients) return;
    final to = _vertical.offset.clamp(0.0, _numbers.position.maxScrollExtent);
    if (_numbers.offset != to) _numbers.jumpTo(to);
  }

  void _hideMenu() {
    if (_menuAt == null && !_menuOverSelection) return;
    setState(() {
      _menuAt = null;
      _menuOverSelection = false;
    });
  }

  @override
  void didUpdateWidget(DocumentView old) {
    super.didUpdateWidget(old);
    if (old.lineSought != widget.lineSought) {
      old.lineSought?.removeListener(_goToLine);
      widget.lineSought?.addListener(_goToLine);
    }
    if (old.spanSought != widget.spanSought) {
      old.spanSought?.removeListener(_goToSpan);
      widget.spanSought?.addListener(_goToSpan);
    }
    if (old.document != widget.document) {
      _search?.cancel();
      _anchor = _extent = _from = _to = _caret = null;
      _composing = null;
      _found = const [];
      _count = 0;
      _current = -1;
      _widest = 0;
      _open();
      _syncInput();
      if (_finding) _searchNow();
    } else if (old.language != widget.language) {
      _language = widget.language ?? _sniff();
      _spans.clear();
    }
    if (old.editable != widget.editable) _focusChanged();
  }

  @override
  void dispose() {
    _input?.close();
    widget.lineSought?.removeListener(_goToLine);
    widget.spanSought?.removeListener(_goToSpan);
    _indexing?.cancel();
    _search?.cancel();
    _searchSoon?.cancel();
    _vertical.removeListener(_scrolled);
    _horizontal.removeListener(_scrolled);
    _vertical.dispose();
    _horizontal.dispose();
    _numbers.dispose();
    _focus.dispose();
    _query.dispose();
    _queryFocus.dispose();
    _replacement.dispose();
    _replaceFocus.dispose();
    super.dispose();
  }

  void _open() {
    _info = _doc.info();
    _blocks.clear();
    _spans.clear();
    _cachedVersion = _info.version;
    _language = widget.language ?? _sniff();
    _indexing?.cancel();
    if (!_info.indexingDone) {
      _indexing = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final info = _doc.info();
        if (info.indexingDone) _indexing?.cancel();
        if (info.version != _info.version || info.indexingDone) {
          setState(() => _info = info);
          // Rows found since may have moved where the selection is shown.
          if (_anchor != null) _select(_anchor!, _extent!, goalX: _goalX);
        }
      });
    }
  }

  CodeLanguage _sniff() =>
      CodeLanguage.sniff(_doc.rows(0, 8).map((r) => r.text).join('\n'));

  // ------------------------------------------------------------------ rows

  TextStyle get _style => mono;

  /// A whole number of pixels: a fraction, added up over millions of rows,
  /// would no longer place them exactly.
  double get _rowHeight => (CodeStyle.fontSize * 1.4).ceilToDouble();

  double _measure(String text) => (TextPainter(
    text: TextSpan(text: text, style: _style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout()).width;

  DocRow? _rowAt(int row) {
    if (_info.version != _cachedVersion) {
      _blocks.clear();
      _spans.clear();
      _cachedVersion = _info.version;
    }
    // A long scroll leaves blocks behind; they are cheap to fetch again.
    if (_blocks.length > 64) {
      _blocks.clear();
      _spans.clear();
    }
    final block = row ~/ _block;
    final rows = _blocks[block] ??= _fetch(block);
    final i = row - block * _block;
    return i < rows.length ? rows[i] : null;
  }

  List<DocRow> _fetch(int block) {
    final rows = _doc.rows(block * _block, _block);
    final widest = rows.fold(_widest, (w, r) => math.max(w, r.text.length));
    if (widest > _widest) {
      _widest = widest;
      // Fetched while laying out; the width follows on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    return rows;
  }

  /// The coloured text of [row], coloured a block at a time so that what
  /// spans rows is seen whole.
  TextSpan _spanOf(int row, Brightness brightness) {
    if (brightness != _cachedBrightness) {
      _spans.clear();
      _cachedBrightness = brightness;
    }
    final block = row ~/ _block;
    final spans = _spans[block] ??= _colour(_blocks[block]!, brightness);
    return spans[row - block * _block];
  }

  /// How the language shown quotes text and writes comments, for the
  /// engine to pair brackets and tell what a block starts inside; none for
  /// plain words.
  DocQuoting? get _quoting => switch (_language) {
    CodeLanguage.json => DocQuoting.json,
    CodeLanguage.javascript => DocQuoting.javaScript,
    CodeLanguage.source => DocQuoting.source,
    CodeLanguage.script => DocQuoting.script,
    CodeLanguage.graphql => DocQuoting.graphql,
    CodeLanguage.xml => DocQuoting.xml,
    _ => null,
  };

  /// What to colour before [first], the first row of a block, so that
  /// the block starts in the right state: an opening quote for a row that
  /// begins inside a string, or, where strings and comments can run over
  /// lines, the opening of the one it begins inside.
  String _before(DocRow first) {
    if (first.segment > 0) return first.quoted ? '"' : '';
    final quoting = _quoting;
    if (quoting == null || quoting == DocQuoting.json || first.start == 0) {
      return '';
    }
    return _doc.openerAt(first.start, quoting);
  }

  List<TextSpan> _colour(List<DocRow> rows, Brightness brightness) {
    if (_language == CodeLanguage.plain || rows.isEmpty) {
      return [for (final r in rows) TextSpan(text: r.text)];
    }
    // The rows of one line go on from each other; lines are joined with
    // the line break between them.
    final before = _before(rows.first);
    final joined = StringBuffer(before);
    final starts = <int>[];
    for (final (i, r) in rows.indexed) {
      if (i > 0 && r.segment == 0) joined.write('\n');
      starts.add(joined.length);
      joined.write(r.text);
    }
    final text = joined.toString();
    final tokens = text.length - before.length > highlightLimit
        ? const <Token>[]
        : tokenize(text, _language);
    final out = <TextSpan>[];
    var t = 0;
    for (final (i, r) in rows.indexed) {
      final start = starts[i];
      final end = start + r.text.length;
      final children = <TextSpan>[];
      var pos = start;
      while (t < tokens.length && tokens[t].end <= start) {
        t++;
      }
      while (t < tokens.length && tokens[t].start < end) {
        final token = tokens[t];
        final s = math.max(token.start, start);
        final e = math.min(token.end, end);
        if (s > pos) children.add(TextSpan(text: text.substring(pos, s)));
        children.add(
          TextSpan(
            text: text.substring(s, e),
            style: TextStyle(color: tokenColor(token.kind, brightness)),
          ),
        );
        pos = e;
        // A token running on into the next row is coloured there too.
        if (token.end > end) break;
        t++;
      }
      if (pos < end) children.add(TextSpan(text: text.substring(pos, end)));
      out.add(TextSpan(children: children));
    }
    return out;
  }

  /// The column in [row]'s text that byte [offset] is at.
  static int _colIn(DocRow row, int offset) {
    if (offset <= row.start) return 0;
    if (offset >= row.end) return row.text.length;
    var bytes = row.start;
    var col = 0;
    for (final rune in row.text.runes) {
      if (bytes >= offset) break;
      bytes += rune < 0x80
          ? 1
          : rune < 0x800
          ? 2
          : rune < 0x10000
          ? 3
          : 4;
      col += rune > 0xFFFF ? 2 : 1;
    }
    return col;
  }

  /// What to paint behind [row]: the selection and what a search found.
  List<_Mark> _marksOf(int index, DocRow row, ColorScheme scheme) {
    final marks = <_Mark>[];
    if (_found.isNotEmpty) {
      // The first match that ends after the row starts.
      var low = 0;
      var high = _found.length;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (_found[middle].end <= row.start) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      for (var i = low; i < _found.length; i++) {
        final match = _found[i];
        if (match.start > row.end ||
            (match.start == row.end && row.end > row.start)) {
          break;
        }
        marks.add(
          _Mark(
            _colIn(row, match.start),
            _colIn(row, match.end),
            i == _current
                ? scheme.tertiary.withValues(alpha: 0.7)
                : scheme.tertiary.withValues(alpha: 0.28),
          ),
        );
      }
    }
    final from = _from;
    final to = _to;
    if (from != null && to != null && index >= from.row && index <= to.row) {
      final start = index == from.row ? from.col : 0;
      final end = index == to.row ? to.col : row.text.length;
      marks.add(
        _Mark(
          start,
          end,
          scheme.primary.withValues(alpha: 0.3),
          pastEnd: index < to.row,
        ),
      );
    }
    if (_brackets case (final a, final b)) {
      for (final at in [a, b]) {
        if (at >= row.start && at < row.end) {
          marks.add(
            _Mark(
              _colIn(row, at),
              _colIn(row, at + 1),
              scheme.primary.withValues(alpha: 0.25),
            ),
          );
        }
      }
    }
    final composing = _composing;
    if (composing != null &&
        composing.$1 <= row.end &&
        composing.$2 >= row.start) {
      marks.add(
        _Mark(
          _colIn(row, composing.$1),
          _colIn(row, composing.$2),
          scheme.onSurface,
          kind: _MarkKind.underline,
        ),
      );
    }
    final caret = _caret;
    if (_showsCaret && caret != null && caret.row == index) {
      marks.add(
        _Mark(caret.col, caret.col, scheme.primary, kind: _MarkKind.caret),
      );
    }
    return marks;
  }

  bool get _showsCaret => widget.editable && _focus.hasPrimaryFocus;

  /// The number beside row [index]: its line's, on the line's first row.
  Widget _number(BuildContext context, int index) {
    final row = _rowAt(index);
    if (row == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Text(
      semanticsLabel: row.segment == 0 ? 'Line ${row.line + 1}' : '',
      row.segment == 0 ? '${row.line + 1}' : '',
      key: ValueKey('${widget.name}-number-$index'),
      textAlign: TextAlign.right,
      style: _style.copyWith(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    );
  }

  Widget _row(BuildContext context, int index, double gap) {
    final row = _rowAt(index);
    if (row == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final marks = _marksOf(index, row, scheme);
    final span = _spanOf(index, theme.brightness);
    final text = Text.rich(
      span,
      key: ValueKey('${widget.name}-row-$index'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: _style.copyWith(color: scheme.onSurface),
    );
    return Row(
      children: [
        SizedBox(width: gap),
        Expanded(
          child: marks.isEmpty
              ? text
              : CustomPaint(
                  painter: _MarkPainter(
                    span: TextSpan(style: _style, children: [span]),
                    marks: marks,
                    textScaler: MediaQuery.textScalerOf(context),
                  ),
                  child: text,
                ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- selection

  /// Selects from [anchor] to [extent], where the caret is. Up and down
  /// keep [goalX], how far across they aim for.
  void _select(int anchor, int extent, {double? goalX}) {
    final (start, end) = anchor <= extent ? (anchor, extent) : (extent, anchor);
    setState(() {
      _anchor = anchor;
      _extent = extent;
      _from = _doc.positionOf(start);
      _to = start == end ? _from : _doc.positionOf(end);
      _caret = extent == start ? _from : _to;
      _goalX = goalX;
      _brackets = start == end ? _bracketsAt(start) : null;
    });
    _syncInput();
    _announce();
  }

  /// Tells a screen reader the line the caret has moved to, and what is
  /// on it.
  void _announce() {
    if (!(MediaQuery.maybeOf(context)?.accessibleNavigation ?? false)) return;
    final caret = _caret;
    if (caret == null) return;
    final row = _rowAt(caret.row);
    if (row == null || row.line == _announced) return;
    _announced = row.line;
    final text = row.text.trim();
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Line ${row.line + 1}${text.isEmpty ? ', blank' : ': $text'}',
      TextDirection.ltr,
    );
  }

  /// The bracket beside [at] and its partner, in bytes, when neither is
  /// in a string or a comment.
  (int, int)? _bracketsAt(int at) {
    final quoting = _quoting;
    if (quoting == null) return null;
    final pair = _doc.bracketPair(at, quoting);
    return pair == null ? null : (pair.start, pair.end);
  }

  void _selectNothing() {
    if (widget.editable) {
      // An editor always has a caret.
      final at = _extent ?? 0;
      _select(at, at);
      return;
    }
    setState(() {
      _anchor = _extent = _from = _to = _caret = null;
    });
  }

  (int, int)? get _selection {
    final anchor = _anchor;
    final extent = _extent;
    if (anchor == null || extent == null || anchor == extent) return null;
    return anchor < extent ? (anchor, extent) : (extent, anchor);
  }

  /// The row a point in the view is over, and the column it is nearest.
  (int, int) _cellAt(Offset local, double gutter, double gap) {
    final y = local.dy + _vertical.offset - _padding;
    final row = (y / _rowHeight).floor().clamp(0, _info.rowCount - 1);
    final r = _rowAt(row);
    if (r == null) return (row, 0);
    final x = local.dx - gutter - gap;
    if (x <= 0) return (row, 0);
    final painter = TextPainter(
      text: TextSpan(text: r.text, style: _style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return (
      row,
      painter.getPositionForOffset(Offset(x, painter.height / 2)).offset,
    );
  }

  int _offsetAt(Offset local, double gutter, double gap) {
    final (row, col) = _cellAt(local, gutter, gap);
    return _doc.offsetOf(row, col);
  }

  /// The word at a point, as bytes.
  (int, int) _wordAt(Offset local, double gutter, double gap) {
    final (row, col) = _cellAt(local, gutter, gap);
    final text = _rowAt(row)?.text ?? '';
    bool word(int i) => i >= 0 && i < text.length && isWordChar(text[i]);
    var start = col;
    var end = col;
    if (word(col) || word(col - 1)) {
      while (word(start - 1)) {
        start--;
      }
      while (word(end)) {
        end++;
      }
    } else if (col < text.length) {
      end = col + 1;
    }
    return (_doc.offsetOf(row, start), _doc.offsetOf(row, end));
  }

  /// A pointer going down at [local], a place in the text as if the
  /// numbers scrolled across with it.
  void _down(PointerDownEvent event, Offset local, double gutter, double gap) {
    // A finger or a pen is followed by the gestures below.
    if (event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus) {
      return;
    }
    if (event.buttons == kSecondaryButton) {
      _focus.requestFocus();
      final offset = _offsetAt(local, gutter, gap);
      final selection = _selection;
      if (selection == null || offset < selection.$1 || offset > selection.$2) {
        _select(offset, offset);
      }
      setState(() {
        _menuOverSelection = false;
        _menuAt = local - Offset(_horizontalOffset, 0);
      });
      return;
    }
    if (event.buttons != kPrimaryButton) return;
    _byTouch = false;
    _hideMenu();
    _focus.requestFocus();
    final now = DateTime.now();
    final again =
        now.difference(_lastDown) < kDoubleTapTimeout &&
        (local - _lastDownAt).distance < kDoubleTapSlop;
    _clicks = again ? _clicks % 3 + 1 : 1;
    _lastDown = now;
    _lastDownAt = local;
    final at = local;
    final keyboard = HardwareKeyboard.instance;
    if (widget.onLink != null &&
        (keyboard.isMetaPressed || keyboard.isControlPressed)) {
      final (row, col) = _cellAt(at, gutter, gap);
      final text = _rowAt(row)?.text ?? '';
      for (final match in _address.allMatches(text)) {
        if (col < match.start || col > match.end) continue;
        final uri = Uri.tryParse(match[0]!);
        if (uri != null && uri.host.isNotEmpty) {
          _clicks = 0;
          widget.onLink!(uri);
          return;
        }
      }
    }
    switch (_clicks) {
      case 2:
        final (start, end) = _wordAt(at, gutter, gap);
        _select(start, end);
      case 3:
        final line = _doc.lineOf(_offsetAt(at, gutter, gap));
        final span = _doc.lineSpan(line);
        _select(span.start, span.end);
      default:
        final offset = _offsetAt(at, gutter, gap);
        if (HardwareKeyboard.instance.isShiftPressed && _anchor != null) {
          _select(_anchor!, offset);
        } else {
          _select(offset, offset);
        }
    }
  }

  /// A web address up to a space or a quote, less the punctuation of the
  /// sentence or code around it.
  static final _address = RegExp(
    r'''https?://[^\s"'<>`\\]*[^\s"'<>`\\.,;:!?)\]}]''',
  );

  double get _horizontalOffset =>
      _horizontal.hasClients ? _horizontal.offset : 0;

  /// A tap with a finger: the caret goes there, and the keyboard comes up.
  void _tapTouch(Offset local, double gutter, double gap) {
    final now = DateTime.now();
    final again =
        now.difference(_lastDown) < kDoubleTapTimeout &&
        (local - _lastDownAt).distance < kDoubleTapSlop;
    _lastDown = again ? DateTime(0) : now;
    _lastDownAt = local;
    if (again) {
      _wordTouch(local, gutter, gap);
      return;
    }
    _focus.requestFocus();
    final offset = _offsetAt(local, gutter, gap);
    final selection = _selection;
    // A tap on what is already selected brings the menu up for it.
    if (selection != null && offset >= selection.$1 && offset <= selection.$2) {
      setState(() => _menuOverSelection = true);
      return;
    }
    _byTouch = false;
    _hideMenu();
    _select(offset, offset);
    _input?.show();
  }

  /// A long press or a double tap with a finger: the word there is
  /// selected, with handles to change it and the menu over it.
  void _wordTouch(Offset local, double gutter, double gap) {
    _focus.requestFocus();
    final (start, end) = _wordAt(local, gutter, gap);
    _pressedWord = (start, end);
    _select(start, end);
    setState(() {
      _byTouch = true;
      _menuAt = null;
      _menuOverSelection = true;
    });
  }

  /// Dragging on after a long press: the selection runs from the word
  /// pressed to where the finger is, whichever way it goes. The menu
  /// waits for the finger to lift.
  void _dragFromWord(Offset local, double gutter, double gap) {
    final word = _pressedWord;
    if (word == null) return;
    final at = _offsetAt(local, gutter, gap);
    if (at < word.$1) {
      _select(word.$2, at);
    } else {
      _select(word.$1, math.max(at, word.$2));
    }
    setState(() => _menuOverSelection = false);
  }

  /// Moves one end of a selection made by touch to where its handle is
  /// dragged; [start] for the handle at its start.
  void _dragHandle(Offset global, {required bool start}) {
    final box = _viewKey.currentContext?.findRenderObject() as RenderBox?;
    final selection = _selection;
    if (box == null || selection == null) return;
    final local = box.globalToLocal(global);
    final gutter = _gutterWidth();
    // The handle hangs below the row it marks.
    final offset = _offsetAt(
      Offset(local.dx + _horizontalOffset, local.dy - _rowHeight),
      gutter,
      CodeStyle.fontSize,
    );
    final other = start ? selection.$2 : selection.$1;
    if (offset == other) return;
    _select(other, offset);
    setState(() => _menuOverSelection = false);
  }

  void _move(
    PointerMoveEvent event,
    Offset local,
    double gutter,
    double gap,
    double height,
  ) {
    // A finger drags to scroll; it selects with handles, which are to come.
    if (event.buttons != kPrimaryButton ||
        _clicks != 1 ||
        _anchor == null ||
        event.kind == PointerDeviceKind.touch) {
      return;
    }
    // Dragging past the top or bottom scrolls on.
    final y = local.dy;
    if (_vertical.hasClients && (y < 0 || y > height)) {
      final position = _vertical.position;
      position.jumpTo(
        (position.pixels + (y < 0 ? y : y - height)).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
    _select(_anchor!, _offsetAt(local, gutter, gap));
  }

  /// Copies the selection; false if there is none, or it is too big.
  Future<bool> _copy() async {
    final selection = _selection;
    if (selection == null) return false;
    final (start, end) = selection;
    if (end - start > copyLimit) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'The selection is ${_megabytes(end - start)} MB; '
            'at most ${_megabytes(copyLimit)} MB can be copied at once.',
          ),
        ),
      );
      return false;
    }
    await Clipboard.setData(ClipboardData(text: _doc.text(start, end)));
    return true;
  }

  static String _megabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 << 20 ? 1 : 0);

  // ------------------------------------------------------------- scrolling

  /// Scrolls byte [offset] into view, if it is not already: with a few
  /// rows above it, or, for the caret moving, [minimal]ly, just enough.
  void _reveal(int offset, {bool minimal = false}) {
    void scroll() {
      if (!mounted || !_vertical.hasClients) return;
      // Asked for now, as lines found meanwhile may have moved it.
      final position = _doc.positionOf(offset);
      final v = _vertical.position;
      final top = position.row * _rowHeight + _padding;
      if (top < v.pixels || top + _rowHeight > v.pixels + v.viewportDimension) {
        final to = !minimal
            // A few rows above it, for context.
            ? top - 3 * _rowHeight
            : top < v.pixels
            ? top - _padding
            : top + _rowHeight + _padding - v.viewportDimension;
        v.jumpTo(to.clamp(0, v.maxScrollExtent));
      }
      if (!_horizontal.hasClients) return;
      final h = _horizontal.position;
      final row = _rowAt(position.row);
      if (row == null) return;
      final x = _measure(
        row.text.substring(0, math.min(position.col, row.text.length)),
      );
      final visible = h.viewportDimension - _gutterWidth() - 32;
      if (x < h.pixels || x > h.pixels + visible) {
        h.jumpTo((x - visible / 2).clamp(0, h.maxScrollExtent));
      }
    }

    // After an edit the rows are laid out again first, as there may be
    // more of them.
    if (_vertical.hasClients && !minimal) {
      scroll();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => scroll());
    }
  }

  void _scrollBy(double by) {
    if (!_vertical.hasClients) return;
    final v = _vertical.position;
    v.jumpTo((v.pixels + by).clamp(0, v.maxScrollExtent));
  }

  void _goToSpan() {
    final span = widget.spanSought?.value;
    if (span == null) return;
    final len = _doc.info().len;
    _focus.requestFocus();
    _select(span.start.clamp(0, len), span.end.clamp(0, len));
    _reveal(span.start.clamp(0, len));
  }

  void _goToLine() {
    final line = widget.lineSought?.value;
    if (line == null) return;
    final span = _doc.lineSpan(math.max(0, line - 1));
    // With the focus here, so that the selection can be copied.
    _focus.requestFocus();
    _select(span.start, span.end);
    _reveal(span.start);
  }

  // ------------------------------------------------------------------ find

  void _openFind({bool replace = false}) {
    final selection = _selection;
    if (selection != null && selection.$2 - selection.$1 <= 200) {
      final text = _doc.text(selection.$1, selection.$2);
      if (!text.contains('\n')) _query.text = text;
    }
    setState(() {
      _finding = true;
      if (replace && widget.editable) _replacing = true;
    });
    _queryFocus.requestFocus();
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
    _searchNow();
  }

  void _closeFind() {
    _search?.cancel();
    _searchSoon?.cancel();
    setState(() {
      _finding = false;
      _found = const [];
      _count = 0;
      _current = -1;
      _searching = false;
      _searchError = null;
    });
    _focus.requestFocus();
  }

  /// Searches again once typing pauses. Unless [move], the matches are
  /// marked without the selection going to one, as after an edit.
  void _searchLater({bool move = true}) {
    _searchSoon?.cancel();
    _searchSoon = Timer(
      const Duration(milliseconds: 150),
      () => _searchNow(move: move),
    );
  }

  void _searchNow({bool move = true}) {
    _searchSoon?.cancel();
    _search?.cancel();
    final query = DocQuery(
      text: _query.text,
      regex: _regex,
      caseSensitive: _caseSensitive,
      wholeWord: _wholeWord,
    );
    final found = <DocSpan>[];
    final from = _selection?.$1 ?? _anchor ?? 0;
    setState(() {
      _found = found;
      _count = 0;
      _current = -1;
      _searchError = null;
      _searching = query.text.isNotEmpty;
    });
    if (query.text.isEmpty) return;
    _search = _doc.search(query).listen((update) {
      if (!mounted) return;
      setState(() {
        found.addAll(update.found);
        // The first match from where the selection is, as soon as there
        // is one; the first of all if there is none after it.
        if (_current < 0) {
          final after = found.indexWhere((m) => m.start >= from);
          if (after >= 0) {
            _current = after;
          } else if (update.done && found.isNotEmpty) {
            _current = 0;
          }
          if (_current >= 0 && move) _show(found[_current]);
        }
        if (update.done) {
          _searching = false;
          _searchError = update.error;
          _count = update.error == null ? update.count : 0;
        } else {
          _count = found.length;
        }
      });
    });
  }

  void _show(DocSpan match) {
    _select(match.start, match.end);
    _reveal(match.start);
  }

  void _step(int by) {
    if (_found.isEmpty) return;
    setState(() => _current = (_current + by) % _found.length);
    _show(_found[_current]);
  }

  /// Puts the replacement where the match the search is on is, and moves
  /// on to the next.
  void _replaceOne() {
    if (!widget.editable || _current < 0 || _current >= _found.length) return;
    final match = _found[_current];
    _edit(match.start, match.end, _replacement.text);
    // From after what was put in, which may itself hold what is sought.
    _searchNow();
  }

  /// Replaces every match found, as one edit.
  Future<void> _replaceAll() async {
    if (!widget.editable || _found.isEmpty || _searching) return;
    final found = _found;
    final total = _count;
    final messenger = ScaffoldMessenger.maybeOf(context);
    _editedAt(found.first.start);
    await _doc.replaceAll(found, _replacement.text);
    if (!mounted) return;
    _composing = null;
    _changed();
    final at = found.first.start;
    _select(at, at);
    _reveal(at);
    if (messenger != null) {
      notify(
        messenger,
        total > found.length
            ? 'Replaced the first ${_thousands(found.length)} of '
                  '${_thousands(total)}; replace again for the rest'
            : 'Replaced ${_thousands(found.length)}',
      );
    }
    _searchNow(move: false);
  }

  // ------------------------------------------------------------------ keys

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;
    if (_menuAt != null || _menuOverSelection) {
      _hideMenu();
      if (key == LogicalKeyboardKey.escape) return KeyEventResult.handled;
    }
    _byTouch = false;

    // While the input method composes, every key is for it.
    if (_composing != null && _focus.hasPrimaryFocus) {
      return KeyEventResult.skipRemainingHandlers;
    }
    if (command && key == LogicalKeyboardKey.keyF) {
      _openFind(replace: keyboard.isAltPressed);
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyG) {
      _step(keyboard.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (_replaceFocus.hasFocus) {
      if (key == LogicalKeyboardKey.escape) {
        _closeFind();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_queryFocus.hasFocus) {
      if (key == LogicalKeyboardKey.escape) {
        _closeFind();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        _step(keyboard.isShiftPressed ? -1 : 1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;

    if (command && key == LogicalKeyboardKey.keyA) {
      _select(0, _info.len);
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyC) {
      _copy();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_finding) {
        _closeFind();
      } else {
        _selectNothing();
      }
      return KeyEventResult.handled;
    }
    if (widget.editable) {
      if (_editKey(key, keyboard)) return KeyEventResult.handled;
      // Anything else typed is for the input method, which makes text of
      // it, and not for shortcuts further up, such as Space or Tab's.
      return command
          ? KeyEventResult.ignored
          : KeyEventResult.skipRemainingHandlers;
    }
    final page = _vertical.hasClients
        ? _vertical.position.viewportDimension - _rowHeight
        : 0.0;
    final far = double.maxFinite / 4;
    final by = switch (key) {
      LogicalKeyboardKey.arrowDown when command => far,
      LogicalKeyboardKey.arrowUp when command => -far,
      LogicalKeyboardKey.arrowDown => _rowHeight,
      LogicalKeyboardKey.arrowUp => -_rowHeight,
      LogicalKeyboardKey.pageDown => page,
      LogicalKeyboardKey.pageUp => -page,
      LogicalKeyboardKey.end => far,
      LogicalKeyboardKey.home => -far,
      _ => null,
    };
    if (by == null) return KeyEventResult.ignored;
    _scrollBy(by);
    return KeyEventResult.handled;
  }

  /// Handles a key that edits or moves the caret, as each platform has
  /// them: on Apple's, Option goes by word and Command to the ends; on
  /// others, Control goes by word, and Home and End to the ends.
  bool _editKey(LogicalKeyboardKey key, HardwareKeyboard keyboard) {
    final shift = keyboard.isShiftPressed;
    final meta = keyboard.isMetaPressed;
    final control = keyboard.isControlPressed;
    final alt = keyboard.isAltPressed;
    final command = _apple ? meta : control;
    final byWord = _apple ? alt : control;
    // To the start or end of the row, rather than by character.
    final toEnd = _apple && meta;
    switch (key) {
      case LogicalKeyboardKey.keyZ when command:
        shift ? _redo() : _undo();
      case LogicalKeyboardKey.keyY when command && !_apple:
        _redo();
      case LogicalKeyboardKey.keyX when command:
        _cut();
      case LogicalKeyboardKey.keyV when command:
        _paste();
      case LogicalKeyboardKey.backspace:
        _deleteBack(word: byWord, row: toEnd);
      case LogicalKeyboardKey.delete:
        _deleteForward(word: byWord, row: toEnd);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter
          when !meta && !control:
        _newLine();
      case LogicalKeyboardKey.tab when !meta && !control && !alt:
        _indent(outdent: shift);
      case LogicalKeyboardKey.arrowLeft:
        _moveAcross(-1, extend: shift, word: byWord, row: toEnd);
      case LogicalKeyboardKey.arrowRight:
        _moveAcross(1, extend: shift, word: byWord, row: toEnd);
      case LogicalKeyboardKey.arrowUp:
        toEnd ? _moveTo(0, extend: shift) : _moveRows(-1, extend: shift);
      case LogicalKeyboardKey.arrowDown:
        toEnd ? _moveTo(_info.len, extend: shift) : _moveRows(1, extend: shift);
      case LogicalKeyboardKey.home:
        command
            ? _moveTo(0, extend: shift)
            : _moveTo(_rowEdge(start: true), extend: shift);
      case LogicalKeyboardKey.end:
        command
            ? _moveTo(_info.len, extend: shift)
            : _moveTo(_rowEdge(start: false), extend: shift);
      case LogicalKeyboardKey.pageUp:
        _moveRows(-_pageRows, extend: shift);
      case LogicalKeyboardKey.pageDown:
        _moveRows(_pageRows, extend: shift);
      default:
        return false;
    }
    return true;
  }

  /// What the input method asks for by name, on macOS, for keys it was
  /// given rather than the view: Control-H, Control-D and the like.
  void _perform(String selector) {
    switch (selector) {
      case 'deleteBackward:':
        _deleteBack();
      case 'deleteForward:':
        _deleteForward();
      case 'deleteWordBackward:':
        _deleteBack(word: true);
      case 'deleteWordForward:':
        _deleteForward(word: true);
      case 'deleteToBeginningOfLine:':
        _deleteBack(row: true);
      case 'deleteToEndOfLine:' || 'deleteToEndOfParagraph:':
        _deleteForward(row: true);
      case 'insertNewline:':
        _newLine();
      case 'insertTab:':
        _indent(outdent: false);
      case 'insertBacktab:':
        _indent(outdent: true);
      case 'moveLeft:':
        _moveAcross(-1, extend: false);
      case 'moveRight:':
        _moveAcross(1, extend: false);
      case 'moveUp:':
        _moveRows(-1, extend: false);
      case 'moveDown:':
        _moveRows(1, extend: false);
      case 'moveToBeginningOfLine:' || 'moveToBeginningOfParagraph:':
        _moveTo(_rowEdge(start: true), extend: false);
      case 'moveToEndOfLine:' || 'moveToEndOfParagraph:':
        _moveTo(_rowEdge(start: false), extend: false);
    }
  }

  // --------------------------------------------------------------- editing

  int get _at => _extent ?? 0;

  /// The selection, or the caret as an empty one.
  (int, int) get _range => _selection ?? (_at, _at);

  int get _pageRows => _vertical.hasClients
      ? math.max(1, _vertical.position.viewportDimension ~/ _rowHeight - 1)
      : 20;

  static String _thousands(int n) {
    final digits = '$n';
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// Takes in an edit: what the document holds now, and whoever is
  /// listening. A search open is run again, as what it found has moved.
  /// Where the first edit since the view last took one in was made, if
  /// the rows fetched were all of the version before it.
  int? _editedFrom;

  /// Notes an edit about to be made at byte [at], so that only the rows
  /// from there on are fetched again.
  void _editedAt(int at) {
    final from = _editedFrom;
    if (from != null) {
      // Another edit before the view takes them in, as a closing bracket
      // put in after an opening one.
      _editedFrom = math.min(from, at);
      return;
    }
    // Rows found meanwhile, or a version not taken in, may have moved any
    // row; then none is kept.
    if (_cachedVersion != _doc.info().version || !_info.indexingDone) {
      _cachedVersion = -1;
      return;
    }
    _editedFrom = at;
  }

  /// Keeps the rows and colours fetched before the first edit noted, and
  /// lets go of the rest, which an edit there may have changed or moved.
  void _keepRowsBeforeEdit(DocInfo info) {
    final from = _editedFrom;
    _editedFrom = null;
    if (from == null || _cachedVersion < 0) return;
    // The row before the edit too, as joining two lines changes it.
    final row = _doc.positionOf(math.max(0, from - 1)).row;
    final block = math.max(0, row - 1) ~/ _block;
    _blocks.removeWhere((b, _) => b >= block);
    _spans.removeWhere((b, _) => b >= block);
    _cachedVersion = info.version;
  }

  void _changed() {
    setState(() {
      _info = _doc.info();
      _keepRowsBeforeEdit(_info);
      _menuAt = null;
      _menuOverSelection = false;
      if (_finding) {
        _found = const [];
        _current = -1;
        _searching = _query.text.isNotEmpty;
      }
    });
    widget.onChanged?.call();
    if (_finding) _searchLater(move: false);
  }

  /// Puts [text] in place of bytes [start] to [end], and the caret after
  /// it, or at [caret].
  void _edit(
    int start,
    int end,
    String text, {
    bool typing = false,
    int? caret,
  }) {
    if (!widget.editable) return;
    _composing = null;
    _editedAt(start);
    _doc.replace(start, end, text, typing: typing);
    final at = caret ?? start + utf8Length(text);
    _changed();
    _select(at, at);
    _reveal(at, minimal: true);
  }

  void _undo() => _afterUndo(_doc.undo());

  void _redo() => _afterUndo(_doc.redo());

  void _afterUndo(DocSpan? changed) {
    if (changed == null) return;
    _editedAt(changed.start);
    _composing = null;
    _changed();
    _select(changed.end, changed.end);
    _reveal(changed.end, minimal: true);
  }

  void _deleteBack({bool word = false, bool row = false}) {
    final selection = _selection;
    if (selection != null) {
      _edit(selection.$1, selection.$2, '');
      return;
    }
    final at = _at;
    if (at == 0) return;
    if (!word && !row && (widget.language ?? _language).bracketed) {
      final around = _doc.text(
        math.max(0, at - 1),
        math.min(_info.len, at + 1),
      );
      if (around.length == 2 && _pairs[around[0]] == around[1]) {
        // An empty pair goes together.
        _edit(at - 1, at + 1, '');
        return;
      }
    }
    var from = row
        ? _rowEdge(start: true)
        : word
        ? previousWord(_doc, at)
        : previousChar(_doc, at);
    if (from >= at) from = previousChar(_doc, at);
    _edit(from, at, '');
  }

  void _deleteForward({bool word = false, bool row = false}) {
    final selection = _selection;
    if (selection != null) {
      _edit(selection.$1, selection.$2, '');
      return;
    }
    final at = _at;
    if (at >= _info.len) return;
    var to = row
        ? _rowEdge(start: false)
        : word
        ? nextWord(_doc, at)
        : nextChar(_doc, at);
    if (to <= at) to = nextChar(_doc, at);
    _edit(at, to, '');
  }

  /// A new line, indented as the one it breaks, and one more after an
  /// opening bracket. Between a pair, the closing one goes to a line of
  /// its own.
  void _newLine() {
    final (start, end) = _range;
    final span = _doc.lineSpan(_doc.lineOf(start));
    // Only so much of a long line is looked at.
    final before = _doc.text(math.max(span.start, start - 4096), start);
    final lineBreak =
        _doc.text(span.end, math.min(_info.len, span.end + 2)) == '\r\n'
        ? '\r\n'
        : '\n';
    var indent = '';
    if (start - span.start <= 4096) {
      final match = RegExp(r'^[ \t]*').firstMatch(before)!;
      indent = match[0]!;
    }
    final trimmed = before.trimRight();
    final opener = trimmed.isEmpty ? '' : trimmed[trimmed.length - 1];
    final closer = const {'{': '}', '[': ']', '(': ')'}[opener];
    var insert = '$lineBreak$indent';
    var tail = '';
    if (closer != null && _language.bracketed) {
      insert += CodeStyle.indent;
      final next = _doc.text(end, math.min(_info.len, end + 1));
      if (next == closer) tail = '$lineBreak$indent';
    }
    _edit(start, end, insert + tail, caret: start + utf8Length(insert));
  }

  /// Tab: indents at the caret, or every line of a selection that spans
  /// lines. With [outdent], takes one level off instead.
  Future<void> _indent({required bool outdent}) async {
    final unit = CodeStyle.indent;
    final (start, end) = _range;
    final first = _doc.lineOf(start);
    var last = _doc.lineOf(end);
    // A selection ending where a line starts does not take that line in.
    if (last > first && _doc.lineSpan(last).start == end) last--;
    if (!outdent && first == last) {
      _edit(start, end, unit);
      return;
    }
    if (last - first >= _indentLimit) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger != null) {
        notify(
          messenger,
          'At most ${_thousands(_indentLimit)} lines can be indented at once.',
        );
      }
      return;
    }
    final spans = <DocSpan>[];
    for (var line = first; line <= last; line++) {
      final span = _doc.lineSpan(line);
      if (!outdent) {
        if (span.end > span.start) {
          spans.add(DocSpan(start: span.start, end: span.start));
        }
        continue;
      }
      final lead = _doc.text(
        span.start,
        math.min(span.end, span.start + unit.length),
      );
      final width = lead.startsWith('\t')
          ? 1
          : RegExp(r'^ *').firstMatch(lead)![0]!.length;
      if (width > 0) {
        spans.add(DocSpan(start: span.start, end: span.start + width));
      }
    }
    if (spans.isEmpty) return;
    _composing = null;
    _editedAt(spans.first.start);
    await _doc.replaceAll(spans, outdent ? '' : unit);
    if (!mounted) return;
    _changed();
    final from = _doc.lineSpan(first).start;
    final to = _doc.lineSpan(last).end;
    if (start == end) {
      // Only the caret's line: it stays where it was in the text.
      final moved = math.max(
        from,
        start +
            (outdent ? -(spans.first.end - spans.first.start) : unit.length),
      );
      _select(moved, moved);
    } else {
      _select(from, to);
    }
  }

  Future<void> _cut() async {
    final selection = _selection;
    if (selection == null) return;
    if (!await _copy()) return;
    _edit(selection.$1, selection.$2, '');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    final (start, end) = _range;
    _edit(start, end, text);
  }

  /// The start or end of the caret's row; for a row past its first, the
  /// end of the row before is the same place.
  int _rowEdge({required bool start}) {
    final row = _caret?.row ?? _doc.positionOf(_at).row;
    return _doc.offsetOf(row, start ? 0 : 1 << 30);
  }

  /// Moves the caret to [offset], selecting on from where it was with
  /// [extend].
  void _moveTo(int offset, {required bool extend, double? goalX}) {
    final at = offset.clamp(0, _info.len);
    _select(extend ? (_anchor ?? _at) : at, at, goalX: goalX);
    _reveal(at, minimal: true);
  }

  /// Moves the caret back or on a character, a word, or to the end of
  /// its row. Without [extend], a selection collapses to that side.
  void _moveAcross(
    int by, {
    required bool extend,
    bool word = false,
    bool row = false,
  }) {
    final selection = _selection;
    if (!extend && selection != null && !word && !row) {
      _moveTo(by < 0 ? selection.$1 : selection.$2, extend: false);
      return;
    }
    final at = _at;
    final to = row
        ? _rowEdge(start: by < 0)
        : word
        ? (by < 0 ? previousWord(_doc, at) : nextWord(_doc, at))
        : (by < 0 ? previousChar(_doc, at) : nextChar(_doc, at));
    _moveTo(to, extend: extend);
  }

  /// Moves the caret [by] rows up or down, keeping as far across as it
  /// can.
  void _moveRows(int by, {required bool extend}) {
    final position = _caret ?? _doc.positionOf(_at);
    final row = _rowAt(position.row);
    final x =
        _goalX ??
        (row == null
            ? 0.0
            : _measure(
                row.text.substring(0, math.min(position.col, row.text.length)),
              ));
    final target = position.row + by;
    if (target < 0) {
      _moveTo(0, extend: extend, goalX: x);
      return;
    }
    if (target >= _info.rowCount) {
      _moveTo(_info.len, extend: extend, goalX: x);
      return;
    }
    final text = _rowAt(target)?.text ?? '';
    final painter = TextPainter(
      text: TextSpan(text: text, style: _style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final col = painter
        .getPositionForOffset(Offset(x, painter.height / 2))
        .offset;
    _moveTo(_doc.offsetOf(target, col), extend: extend, goalX: x);
  }

  // --------------------------------------------------------- input method

  void _focusChanged() {
    if (_showsCaret) {
      if (_extent == null) _select(0, 0);
      _attach();
    } else {
      _detach();
    }
    if (mounted) setState(() {});
  }

  void _attach() {
    if (_input?.attached ?? false) return;
    _input = TextInput.attach(
      _client,
      TextInputConfiguration(
        viewId: View.of(context).viewId,
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        enableDeltaModel: true,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        keyboardAppearance: Theme.of(context).brightness,
      ),
    );
    _syncInput(force: true);
    _input!.show();
  }

  void _detach() {
    _input?.close();
    _input = null;
    _composing = null;
  }

  /// The platform closed the connection, as when the keyboard is put away.
  void _inputClosed() {
    _input = null;
    if (_composing != null) setState(() => _composing = null);
  }

  /// Tells the input method about the rows around the selection, if they
  /// are not what it was last told.
  void _syncInput({bool force = false}) {
    final input = _input;
    if (input == null || !input.attached) return;
    final value = _window();
    if (force || value != _sent) {
      _sent = value;
      input.setEditingState(value);
    }
    _placeInput();
  }

  /// The rows from the selection's start to its end, as the input method
  /// is to see them; or, for a selection too big for that, nothing.
  TextEditingValue _window() {
    final anchor = _anchor ?? 0;
    final extent = _extent ?? anchor;
    final low = math.min(anchor, extent);
    final high = math.max(anchor, extent);
    final first = _doc.positionOf(low).row;
    final last = high == low ? first : _doc.positionOf(high).row;
    if (last - first < 16) {
      final rows = _doc.rows(first, last - first + 1);
      if (rows.isNotEmpty) {
        final start = rows.first.start;
        final end = math.max(rows.last.end, high);
        if (end - start <= 32 * 1024) {
          final text = _doc.text(start, end);
          // Bytes that are not UTF-8 would put the two out of step.
          if (utf8Length(text) == end - start) {
            _windowStart = start;
            _windowEnd = end;
            _windowWhole = true;
            int at(int offset) => unitsOf(text, offset - start);
            final composing = _composing;
            return TextEditingValue(
              text: text,
              selection: TextSelection(
                baseOffset: at(anchor),
                extentOffset: at(extent),
              ),
              composing:
                  composing == null ||
                      composing.$1 < start ||
                      composing.$2 > end
                  ? TextRange.empty
                  : TextRange(start: at(composing.$1), end: at(composing.$2)),
            );
          }
        }
      }
    }
    _windowStart = low;
    _windowEnd = high;
    _windowWhole = false;
    return const TextEditingValue(
      selection: TextSelection.collapsed(offset: 0),
    );
  }

  /// The bytes [range] of the input method's [text] stands for.
  (int, int) _bytesOf(String text, TextRange range) {
    if (!_windowWhole) return (_windowStart, _windowEnd);
    final start = range.start.clamp(0, text.length);
    final end = range.end.clamp(start, text.length);
    final at = _windowStart + utf8Length(text, 0, start);
    return (at, at + utf8Length(text, start, end));
  }

  /// Takes in what the input method did: text typed, composed or rubbed
  /// out, and the selection moved.
  void _applyDeltas(List<TextEditingDelta> deltas) {
    if (!widget.editable) return;
    var value = _sent;
    var changed = false;
    for (final delta in deltas) {
      final (TextRange? range, String inserted) = switch (delta) {
        final TextEditingDeltaInsertion d => (
          TextRange.collapsed(d.insertionOffset),
          d.textInserted,
        ),
        final TextEditingDeltaDeletion d => (d.deletedRange, ''),
        final TextEditingDeltaReplacement d => (
          d.replacedRange,
          d.replacementText,
        ),
        _ => (null, ''),
      };
      if (range != null) {
        final (start, end) = _bytesOf(value.text, range);
        _editedAt(start);
        _doc.replace(start, end, inserted, typing: true);
        changed = true;
        if (!_windowWhole) {
          // What it stood for is gone; it is now what was put in.
          _windowWhole = true;
          value = TextEditingValue(
            text: inserted,
            selection: TextSelection.collapsed(offset: inserted.length),
          );
          continue;
        }
      }
      try {
        value = delta.apply(value);
      } catch (_) {
        // Out of step with what it was told: it is told again below.
        break;
      }
    }
    if (!changed &&
        value.selection == _sent.selection &&
        value.composing == _sent.composing) {
      return;
    }
    if (deltas case [final TextEditingDeltaInsertion typed]
        when typed.textInserted.length == 1 &&
            value.composing.isCollapsed &&
            _windowWhole &&
            _pairTyped(typed, value)) {
      return;
    }
    if (!changed && !_windowWhole) {
      // A selection too big to tell stays as it is.
      return;
    }
    int bytes(int units) =>
        _windowStart +
        utf8Length(value.text, 0, units.clamp(0, value.text.length));
    final composing = value.composing;
    _composing = composing.isValid && !composing.isCollapsed
        ? (bytes(composing.start), bytes(composing.end))
        : null;
    // What the input method holds now, so that it is not told it again.
    _sent = value;
    if (changed) _changed();
    final selection = value.selection;
    final base = selection.isValid
        ? bytes(selection.baseOffset)
        : bytes(value.text.length);
    final extent = selection.isValid ? bytes(selection.extentOffset) : base;
    _select(base, extent);
    if (changed) _reveal(extent, minimal: true);
  }

  static const _pairs = {'{': '}', '[': ']', '(': ')', '"': '"'};

  /// What typing one character does beyond putting it in, in code: an
  /// opening bracket or quote brings its closing one, and typing a closing
  /// one that is already there steps over it. True if it did either, the
  /// character itself being in the document already.
  bool _pairTyped(TextEditingDeltaInsertion typed, TextEditingValue value) {
    final language = widget.language ?? _language;
    if (!language.bracketed) return false;
    final char = typed.textInserted;
    // Where the character went, and the caret after it.
    final at = _windowStart + utf8Length(_sent.text, 0, typed.insertionOffset);
    final after = at + 1;
    final len = _doc.info().len;
    final next = _doc.text(after, math.min(len, after + 1));
    if (_pairs.containsValue(char) && next == char) {
      // Typed over: the one just put in goes, and the caret steps on.
      _editedAt(at);
      _doc.replace(at, after, '', typing: true);
      _sent = value;
      _changed();
      _select(after, after);
      return true;
    }
    final closer = _pairs[char];
    if (closer == null) return false;
    if (next.isNotEmpty && !' \t\r\n)]},'.contains(next)) return false;
    if (char == '"' &&
        at > 0 &&
        isWordChar(_doc.text(previousChar(_doc, at), at))) {
      return false;
    }
    _editedAt(after);
    _doc.replace(after, after, closer, typing: true);
    _sent = value;
    _changed();
    _select(after, after);
    return true;
  }

  /// Tells the platform where the text and the caret are, so that a
  /// window of candidates opens beside what is being composed.
  void _placeInput() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final input = _input;
      if (!mounted || input == null || !input.attached) return;
      final box = _viewKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      input.setEditableSizeAndTransform(box.size, box.getTransformTo(null));
      final caret = _caretRect(_composing?.$1 ?? _at);
      if (caret != null) {
        input.setCaretRect(caret);
        input.setComposingRect(caret);
      }
    });
  }

  /// Where byte [offset] is in the rows' area, as a caret's height.
  Rect? _caretRect(int offset) {
    final position = _doc.positionOf(offset);
    final row = _rowAt(position.row);
    if (row == null) return null;
    final x =
        _gutterWidth() +
        CodeStyle.fontSize +
        _measure(
          row.text.substring(0, math.min(position.col, row.text.length)),
        ) -
        (_horizontal.hasClients ? _horizontal.offset : 0);
    final y =
        _padding +
        position.row * _rowHeight -
        (_vertical.hasClients ? _vertical.offset : 0);
    return Rect.fromLTWH(x, y, 2, _rowHeight);
  }

  // ----------------------------------------------------------------- build

  double _gutterWidth() {
    final digits = math.max(3, '${_info.lineCount}'.length);
    return _measure('0' * digits) + 12;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final gutter = _gutterWidth();
    final gap = CodeStyle.fontSize;
    final textWidth = _measure('0') * (_widest + 2);
    final name = widget.name;

    final view = LayoutBuilder(
      key: _viewKey,
      builder: (context, constraints) {
        final width = math.max(constraints.maxWidth - gutter, gap + textWidth);
        // Where a point in the text is as if the numbers scrolled across
        // with it, as the view works places out from.
        Offset withGutter(Offset local) => local + Offset(gutter, 0);
        // The scrollbar down the side stays in view however far it is
        // scrolled across; it is for the list, one level in.
        final scrolled = Scrollbar(
          controller: _vertical,
          thumbVisibility: true,
          interactive: true,
          notificationPredicate: (notification) => notification.depth == 1,
          child: Scrollbar(
            controller: _horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                height: constraints.maxHeight,
                child: Listener(
                  onPointerDown: (e) =>
                      _down(e, withGutter(e.localPosition), gutter, gap),
                  onPointerMove: (e) => _move(
                    e,
                    withGutter(e.localPosition),
                    gutter,
                    gap,
                    constraints.maxHeight,
                  ),
                  child: GestureDetector(
                    supportedDevices: const {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.stylus,
                    },
                    // A double tap is told apart by hand: a recognizer for
                    // it would hold every single tap back until it knew.
                    onTapUp: (d) =>
                        _tapTouch(withGutter(d.localPosition), gutter, gap),
                    onLongPressStart: (d) =>
                        _wordTouch(withGutter(d.localPosition), gutter, gap),
                    onLongPressMoveUpdate: (d) =>
                        _dragFromWord(withGutter(d.localPosition), gutter, gap),
                    onLongPressEnd: (_) {
                      if (_pressedWord != null) {
                        setState(() => _menuOverSelection = true);
                      }
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.text,
                      child: ListView.builder(
                        key: Key(name),
                        controller: _vertical,
                        padding: const EdgeInsets.symmetric(vertical: _padding),
                        itemExtent: _rowHeight,
                        itemCount: _info.rowCount,
                        itemBuilder: (context, row) => _row(context, row, gap),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // The numbers stay in view however far the text is scrolled
        // across; they follow it up and down, and scroll it from there.
        final numbers = SizedBox(
          width: gutter,
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) _scrollBy(e.scrollDelta.dy);
            },
            onPointerPanZoomUpdate: (e) => _scrollBy(-e.panDelta.dy),
            child: GestureDetector(
              onVerticalDragUpdate: (d) => _scrollBy(-d.delta.dy),
              child: ListView.builder(
                controller: _numbers,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: _padding),
                itemExtent: _rowHeight,
                itemCount: _info.rowCount,
                itemBuilder: _number,
              ),
            ),
          ),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) => _followText());
        return Semantics(
          container: true,
          textField: widget.editable,
          readOnly: !widget.editable,
          multiline: true,
          label: widget.name,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  numbers,
                  Expanded(child: scrolled),
                ],
              ),
              ..._handles(scheme),
              ?_menu(theme, constraints),
            ],
          ),
        );
      },
    );

    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_info.indexingDone)
                LinearProgressIndicator(
                  key: Key('$name-indexing'),
                  minHeight: 2,
                  value: _info.len == 0 ? null : _info.indexed / _info.len,
                ),
              Expanded(child: view),
              if (widget.status) _statusLine(theme),
            ],
          ),
          Positioned(
            top: 4,
            right: 18,
            child: _finding ? _findBar(theme) : _findButton(scheme),
          ),
        ],
      ),
    );
  }

  /// The handles at either end of a selection made by touch, to drag.
  List<Widget> _handles(ColorScheme scheme) {
    final selection = _selection;
    if (!_byTouch || selection == null || _composing != null) return const [];
    Widget handle(int offset, {required bool start}) {
      final rect = _caretRect(offset);
      if (rect == null) return const SizedBox.shrink();
      const size = 22.0;
      return Positioned(
        left: rect.left - size / 2,
        top: rect.bottom,
        child: GestureDetector(
          key: Key('${widget.name}-handle-${start ? 'start' : 'end'}'),
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => _dragHandle(d.globalPosition, start: start),
          onPanEnd: (_) => setState(() => _menuOverSelection = true),
          child: CustomPaint(
            size: const Size(size, size),
            painter: _HandlePainter(scheme.primary),
          ),
        ),
      );
    }

    return [
      handle(selection.$1, start: true),
      handle(selection.$2, start: false),
    ];
  }

  /// Cut, Copy, Paste and Select All, over the selection or where the
  /// view was right-clicked.
  Widget? _menu(ThemeData theme, BoxConstraints constraints) {
    Offset? at = _menuAt;
    if (at == null && _menuOverSelection) {
      final rect = _caretRect(_selection?.$1 ?? _at);
      if (rect != null) {
        // Above the selection, or, with no room there, below it and its
        // handles, so that it never covers what it is for.
        final below = _caretRect(_selection?.$2 ?? _at) ?? rect;
        at = rect.top >= 48
            ? Offset(rect.left, rect.top - 44)
            : Offset(rect.left, below.bottom + 28);
      }
    }
    if (at == null) return null;
    final name = widget.name;
    final selected = _selection != null;
    final editable = widget.editable;
    Widget item(String key, String label, VoidCallback onTap) => TextButton(
      key: Key('$name-menu-$key'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      onPressed: () {
        _hideMenu();
        onTap();
      },
      child: Text(label),
    );
    final items = [
      if (editable && selected) item('cut', 'Cut', _cut),
      if (selected) item('copy', 'Copy', _copy),
      if (editable) item('paste', 'Paste', _paste),
      item('select-all', 'Select All', () => _select(0, _info.len)),
    ];
    const width = 300.0;
    return Positioned(
      left: at.dx.clamp(0, math.max(0, constraints.maxWidth - width)),
      top: at.dy.clamp(0, math.max(0, constraints.maxHeight - 44)),
      child: Material(
        key: Key('$name-menu'),
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surfaceContainerHigh,
        child: Row(mainAxisSize: MainAxisSize.min, children: items),
      ),
    );
  }

  /// Where the caret is, what is selected, and what the document is.
  Widget _statusLine(ThemeData theme) {
    final scheme = theme.colorScheme;
    final caret = _caret ?? _doc.positionOf(_at);
    final row = _rowAt(caret.row);
    String where;
    if (row == null) {
      where = '';
    } else if (row.segment == 0) {
      where = 'Ln ${_thousands(row.line + 1)}, Col ${caret.col + 1}';
    } else if (row.segment <= 64) {
      // The rows of the line before this one are counted in.
      final before = _doc.rows(caret.row - row.segment, row.segment);
      final col = before.fold(caret.col, (n, r) => n + r.text.length);
      where = 'Ln ${_thousands(row.line + 1)}, Col ${_thousands(col + 1)}';
    } else {
      where = 'Ln ${_thousands(row.line + 1)}';
    }
    final selection = _selection;
    final parts = [
      where,
      if (selection != null)
        '${formatSize(selection.$2 - selection.$1)} selected',
      '${_thousands(_info.lineCount)} '
          '${_info.lineCount == 1 ? 'line' : 'lines'}'
          '${_info.indexingDone ? '' : ' so far'}',
      formatSize(_info.len),
      _language.label,
    ];
    return Container(
      key: Key('${widget.name}-status'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Text(
        parts.where((p) => p.isNotEmpty).join('   ·   '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _findButton(ColorScheme scheme) => Opacity(
    opacity: 0.75,
    child: Material(
      color: scheme.surface.withValues(alpha: 0.85),
      shape: const CircleBorder(),
      child: IconButton(
        key: Key('${widget.name}-find'),
        tooltip: 'Find (${shortcutModifier}F)',
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        color: scheme.onSurfaceVariant,
        icon: const Icon(Icons.search),
        onPressed: _openFind,
      ),
    ),
  );

  Widget _findBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final name = widget.name;
    final none = _query.text.isNotEmpty && !_searching && _found.isEmpty;
    final count = _searchError != null
        ? 'Not a valid pattern'
        : _searching
        ? '${_found.length}…'
        : _found.isEmpty
        ? (none ? 'None' : '')
        : '${_current + 1} of $_count';
    Widget button(String key, String tip, IconData icon, VoidCallback? onTap) =>
        IconButton(
          key: Key('$name-find-$key'),
          tooltip: tip,
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          icon: Icon(icon),
          onPressed: onTap,
        );
    Widget toggle(
      String key,
      String tip,
      String label,
      bool on,
      VoidCallback f,
    ) => Tooltip(
      message: tip,
      child: InkWell(
        key: Key('$name-find-$key'),
        borderRadius: BorderRadius.circular(4),
        onTap: () {
          f();
          _searchNow();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: BoxDecoration(
            color: on ? scheme.primary.withValues(alpha: 0.2) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: on ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    const fieldDecoration = InputDecoration(
      isDense: true,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: EdgeInsets.symmetric(vertical: 6),
    );
    final compact = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 28),
    );
    final findRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.editable)
          IconButton(
            key: Key('$name-replace-toggle'),
            tooltip: _replacing
                ? 'Hide replace'
                : 'Replace ($shortcutModifier⌥F)',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: Icon(_replacing ? Icons.expand_more : Icons.chevron_right),
            onPressed: () => setState(() => _replacing = !_replacing),
          ),
        SizedBox(
          width: 150,
          child: TextField(
            key: Key('$name-find-field'),
            controller: _query,
            focusNode: _queryFocus,
            autocorrect: false,
            enableSuggestions: false,
            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
            decoration: fieldDecoration.copyWith(hintText: 'Find'),
            onChanged: (_) => _searchLater(),
            // Stays in the field, ready for the next one.
            onEditingComplete: () => _step(1),
          ),
        ),
        toggle(
          'case',
          'Match case',
          'Aa',
          _caseSensitive,
          () => _caseSensitive = !_caseSensitive,
        ),
        toggle(
          'word',
          'Whole words',
          'W',
          _wholeWord,
          () => _wholeWord = !_wholeWord,
        ),
        toggle(
          'regex',
          'Regular expression',
          '.*',
          _regex,
          () => _regex = !_regex,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            count,
            key: Key('$name-find-count'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: none || _searchError != null
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
        button(
          'previous',
          'Previous (⇧Enter)',
          Icons.keyboard_arrow_up,
          _found.isEmpty ? null : () => _step(-1),
        ),
        button(
          'next',
          'Next (Enter)',
          Icons.keyboard_arrow_down,
          _found.isEmpty ? null : () => _step(1),
        ),
        button('close', 'Close (Esc)', Icons.close, _closeFind),
      ],
    );
    final canReplace = _found.isNotEmpty && _searchError == null;
    return Material(
      elevation: 3,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            findRow,
            if (_replacing && widget.editable)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 28),
                  SizedBox(
                    width: 150,
                    child: TextField(
                      key: Key('$name-replace-field'),
                      controller: _replacement,
                      focusNode: _replaceFocus,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                      decoration: fieldDecoration.copyWith(
                        hintText: 'Replace with',
                      ),
                      onEditingComplete: _replaceOne,
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton(
                    key: Key('$name-replace-one'),
                    style: compact,
                    onPressed: canReplace ? _replaceOne : null,
                    child: const Text('Replace'),
                  ),
                  TextButton(
                    key: Key('$name-replace-all'),
                    style: compact,
                    onPressed: canReplace && !_searching ? _replaceAll : null,
                    child: const Text('All'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

enum _MarkKind { fill, underline, caret }

/// A stretch of a row's text to paint behind, by column: a fill, a line
/// under text being composed, or the caret.
class _Mark {
  const _Mark(
    this.start,
    this.end,
    this.color, {
    this.pastEnd = false,
    this.kind = _MarkKind.fill,
  });

  final int start;
  final int end;
  final Color color;
  final _MarkKind kind;

  /// Whether it goes on past the end of the row, as a selection of several
  /// lines does, which is shown by a little more after the text.
  final bool pastEnd;
}

/// The view as the platform's input method sees it.
class _InputClient with TextInputClient, DeltaTextInputClient {
  _InputClient(this.view);

  final _DocumentViewState view;

  @override
  TextEditingValue? get currentTextEditingValue => view._sent;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {}

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) =>
      view._applyDeltas(deltas);

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) view._newLine();
  }

  @override
  void performSelector(String selectorName) => view._perform(selectorName);

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() => view._inputClosed();
}

/// A selection handle: a round head on a stem, under the end it marks.
class _HandlePainter extends CustomPainter {
  _HandlePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final r = size.width / 2;
    canvas
      ..drawRect(Rect.fromLTWH(r - 1, 0, 2, r), paint)
      ..drawCircle(Offset(r, r + r / 2), r / 1.6, paint);
  }

  @override
  bool shouldRepaint(_HandlePainter old) => old.color != color;
}

class _MarkPainter extends CustomPainter {
  _MarkPainter({
    required this.span,
    required this.marks,
    required this.textScaler,
  });

  final TextSpan span;
  final List<_Mark> marks;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final top = (size.height - painter.height) / 2;
    final length = span.toPlainText().length;
    for (final mark in marks) {
      final paint = Paint()..color = mark.color;
      final start = mark.start.clamp(0, length);
      final end = mark.end.clamp(start, length);
      var left = painter
          .getOffsetForCaret(TextPosition(offset: start), Rect.zero)
          .dx;
      if (mark.kind == _MarkKind.caret) {
        canvas.drawRect(
          Rect.fromLTWH(math.max(0, left - 1), top, 2, painter.height),
          paint,
        );
        continue;
      }
      var right = painter
          .getOffsetForCaret(TextPosition(offset: end), Rect.zero)
          .dx;
      if (mark.pastEnd) right += painter.preferredLineHeight / 3;
      if (right <= left) continue;
      left = math.max(0, left);
      canvas.drawRect(
        mark.kind == _MarkKind.underline
            ? Rect.fromLTRB(
                left,
                top + painter.height - 1.5,
                right,
                top + painter.height,
              )
            : Rect.fromLTRB(left, top, right, top + painter.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.span != span ||
      !listEquals(old.marks, marks) ||
      old.textScaler != textScaler;
}

/// Text already held as a [String], such as a response or a spec too long
/// for the editor, shown in a [DocumentView]. It makes the document and
/// lets go of it. Outside an [EngineScope], as in some widget tests, the
/// document is held in Dart.
class DocumentText extends StatefulWidget {
  const DocumentText({
    super.key,
    required this.text,
    this.name = 'document',
    this.language,
    this.lineSought,
    this.onLink,
    this.spanSought,
  });

  final String text;
  final String name;
  final CodeLanguage? language;
  final ValueListenable<int?>? lineSought;
  final ValueChanged<Uri>? onLink;
  final ValueListenable<DocSpan?>? spanSought;

  @override
  State<DocumentText> createState() => _DocumentTextState();
}

class _DocumentTextState extends State<DocumentText> {
  TextDocument? _document;

  TextDocument _make() =>
      Engine.maybeOf(context)?.documentOf(widget.text) ??
      MemoryDocument(widget.text);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _document ??= _make();
  }

  @override
  void didUpdateWidget(DocumentText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _document?.dispose();
      _document = _make();
    }
  }

  @override
  void dispose() {
    _document?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DocumentView(
    document: _document!,
    name: widget.name,
    language: widget.language,
    lineSought: widget.lineSought,
    onLink: widget.onLink,
    spanSought: widget.spanSought,
  );
}
