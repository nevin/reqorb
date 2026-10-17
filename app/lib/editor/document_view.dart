import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/document/memory_document.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/syntax.dart';
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

/// Text of any size, shown a screenful at a time: coloured, numbered,
/// selectable with the mouse, copied and searched. Only the rows in view
/// are asked of the document, so a gigabyte opens as fast as a line.
///
/// The rows are keyed `<name>`; the numbers beside them
/// `<name>-number-<row>`; the find bar's parts `<name>-find`,
/// `<name>-find-field`, `<name>-find-count`, `<name>-find-next`,
/// `<name>-find-previous`, `<name>-find-close`, `<name>-find-case`,
/// `<name>-find-regex` and `<name>-find-word`.
class DocumentView extends StatefulWidget {
  const DocumentView({
    super.key,
    required this.document,
    this.name = 'document',
    this.language,
    this.lineSought,
  });

  /// What is shown. Whoever made it disposes of it.
  final TextDocument document;
  final String name;

  /// What the text is written in; null to go by how it starts.
  final CodeLanguage? language;

  /// A line to select and bring into view, counted from 1. Asking for the
  /// same line again goes through null.
  final ValueListenable<int?>? lineSought;

  @override
  State<DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends State<DocumentView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _focus = FocusNode(debugLabel: 'document');
  final _query = TextEditingController();
  final _queryFocus = FocusNode(debugLabel: 'document find');

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

  /// For telling a double or triple click from separate ones.
  DateTime _lastDown = DateTime(0);
  Offset _lastDownAt = Offset.zero;
  int _clicks = 0;

  bool _finding = false;
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

  @override
  void initState() {
    super.initState();
    _open();
    widget.lineSought?.addListener(_goToLine);
  }

  @override
  void didUpdateWidget(DocumentView old) {
    super.didUpdateWidget(old);
    if (old.lineSought != widget.lineSought) {
      old.lineSought?.removeListener(_goToLine);
      widget.lineSought?.addListener(_goToLine);
    }
    if (old.document != widget.document) {
      _search?.cancel();
      _anchor = _extent = _from = _to = null;
      _found = const [];
      _count = 0;
      _current = -1;
      _widest = 0;
      _open();
      if (_finding) _searchNow();
    } else if (old.language != widget.language) {
      _language = widget.language ?? _sniff();
      _spans.clear();
    }
  }

  @override
  void dispose() {
    widget.lineSought?.removeListener(_goToLine);
    _indexing?.cancel();
    _search?.cancel();
    _searchSoon?.cancel();
    _vertical.dispose();
    _horizontal.dispose();
    _focus.dispose();
    _query.dispose();
    _queryFocus.dispose();
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

  List<TextSpan> _colour(List<DocRow> rows, Brightness brightness) {
    if (_language == CodeLanguage.plain) {
      return [for (final r in rows) TextSpan(text: r.text)];
    }
    final joined = rows.map((r) => r.text).join('\n');
    final tokens = joined.length > highlightLimit
        ? const <Token>[]
        : tokenize(joined, _language);
    final out = <TextSpan>[];
    var t = 0;
    var at = 0;
    for (final r in rows) {
      final start = at;
      final end = at + r.text.length;
      final children = <TextSpan>[];
      var pos = start;
      while (t < tokens.length && tokens[t].end <= start) {
        t++;
      }
      while (t < tokens.length && tokens[t].start < end) {
        final token = tokens[t];
        final s = math.max(token.start, start);
        final e = math.min(token.end, end);
        if (s > pos) children.add(TextSpan(text: joined.substring(pos, s)));
        children.add(
          TextSpan(
            text: joined.substring(s, e),
            style: TextStyle(color: tokenColor(token.kind, brightness)),
          ),
        );
        pos = e;
        // A token running on into the next row is coloured there too.
        if (token.end > end) break;
        t++;
      }
      if (pos < end) children.add(TextSpan(text: joined.substring(pos, end)));
      out.add(TextSpan(children: children));
      at = end + 1;
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
    return marks;
  }

  Widget _row(BuildContext context, int index, double gutter, double gap) {
    final row = _rowAt(index);
    if (row == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final marks = _marksOf(index, row, scheme);
    final span = _spanOf(index, theme.brightness);
    final text = Text.rich(
      span,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: _style.copyWith(color: scheme.onSurface),
    );
    return Row(
      children: [
        SizedBox(
          width: gutter,
          child: Text(
            row.segment == 0 ? '${row.line + 1}' : '',
            key: ValueKey('${widget.name}-number-$index'),
            textAlign: TextAlign.right,
            style: _style.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
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

  void _select(int anchor, int extent) {
    final (start, end) = anchor <= extent ? (anchor, extent) : (extent, anchor);
    setState(() {
      _anchor = anchor;
      _extent = extent;
      _from = _doc.positionOf(start);
      _to = _doc.positionOf(end);
    });
  }

  void _selectNothing() => setState(() {
    _anchor = _extent = _from = _to = null;
  });

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
    bool word(int i) =>
        i >= 0 && i < text.length && _wordChar.hasMatch(text[i]);
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

  static final _wordChar = RegExp(r'[\p{L}\p{N}_$]', unicode: true);

  void _down(PointerDownEvent event, double gutter, double gap) {
    if (event.buttons != kPrimaryButton) return;
    _focus.requestFocus();
    final now = DateTime.now();
    final again =
        now.difference(_lastDown) < kDoubleTapTimeout &&
        (event.localPosition - _lastDownAt).distance < kDoubleTapSlop;
    _clicks = again ? _clicks % 3 + 1 : 1;
    _lastDown = now;
    _lastDownAt = event.localPosition;
    final at = event.localPosition;
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

  void _move(PointerMoveEvent event, double gutter, double gap, double height) {
    if (event.buttons != kPrimaryButton || _clicks != 1 || _anchor == null) {
      return;
    }
    // Dragging past the top or bottom scrolls on.
    final y = event.localPosition.dy;
    if (_vertical.hasClients && (y < 0 || y > height)) {
      final position = _vertical.position;
      position.jumpTo(
        (position.pixels + (y < 0 ? y : y - height)).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
    _select(_anchor!, _offsetAt(event.localPosition, gutter, gap));
  }

  Future<void> _copy() async {
    final selection = _selection;
    if (selection == null) return;
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
      return;
    }
    await Clipboard.setData(ClipboardData(text: _doc.text(start, end)));
  }

  static String _megabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 << 20 ? 1 : 0);

  // ------------------------------------------------------------- scrolling

  /// Scrolls byte [offset] into view, if it is not already.
  void _reveal(int offset) {
    final position = _doc.positionOf(offset);
    void scroll() {
      if (!mounted || !_vertical.hasClients) return;
      final v = _vertical.position;
      final top = position.row * _rowHeight + _padding;
      if (top < v.pixels || top + _rowHeight > v.pixels + v.viewportDimension) {
        // A few rows above it, for context.
        v.jumpTo((top - 3 * _rowHeight).clamp(0, v.maxScrollExtent));
      }
      if (!_horizontal.hasClients) return;
      final h = _horizontal.position;
      final row = _rowAt(position.row);
      if (row == null) return;
      final x = _measure(row.text.substring(0, position.col));
      final visible = h.viewportDimension - _gutterWidth() - 32;
      if (x < h.pixels || x > h.pixels + visible) {
        h.jumpTo((x - visible / 2).clamp(0, h.maxScrollExtent));
      }
    }

    if (_vertical.hasClients) {
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

  void _openFind() {
    final selection = _selection;
    if (selection != null && selection.$2 - selection.$1 <= 200) {
      final text = _doc.text(selection.$1, selection.$2);
      if (!text.contains('\n')) _query.text = text;
    }
    setState(() => _finding = true);
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

  void _searchLater() {
    _searchSoon?.cancel();
    _searchSoon = Timer(const Duration(milliseconds: 150), _searchNow);
  }

  void _searchNow() {
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
          if (_current >= 0) _show(found[_current]);
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

  // ------------------------------------------------------------------ keys

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;

    if (command && key == LogicalKeyboardKey.keyF) {
      _openFind();
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyG) {
      _step(keyboard.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
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
    if (!_focus.hasFocus) return KeyEventResult.ignored;

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
      builder: (context, constraints) {
        final width = math.max(constraints.maxWidth, gutter + gap + textWidth);
        // The scrollbar down the side stays in view however far it is
        // scrolled across; it is for the list, one level in.
        return Scrollbar(
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
                  onPointerDown: (e) => _down(e, gutter, gap),
                  onPointerMove: (e) =>
                      _move(e, gutter, gap, constraints.maxHeight),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.text,
                    child: ListView.builder(
                      key: Key(name),
                      controller: _vertical,
                      padding: const EdgeInsets.symmetric(vertical: _padding),
                      itemExtent: _rowHeight,
                      itemCount: _info.rowCount,
                      itemBuilder: (context, row) =>
                          _row(context, row, gutter, gap),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    return Focus(
      focusNode: _focus,
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
    return Material(
      elevation: 3,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 150,
              child: TextField(
                key: Key('$name-find-field'),
                controller: _query,
                focusNode: _queryFocus,
                autocorrect: false,
                enableSuggestions: false,
                style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                  hintText: 'Find',
                ),
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
        ),
      ),
    );
  }
}

/// A stretch of a row's text to paint behind, by column.
class _Mark {
  const _Mark(this.start, this.end, this.color, {this.pastEnd = false});

  final int start;
  final int end;
  final Color color;

  /// Whether it goes on past the end of the row, as a selection of several
  /// lines does, which is shown by a little more after the text.
  final bool pastEnd;
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
      var right = painter
          .getOffsetForCaret(TextPosition(offset: end), Rect.zero)
          .dx;
      if (mark.pastEnd) right += painter.preferredLineHeight / 3;
      if (right <= left) continue;
      left = math.max(0, left);
      canvas.drawRect(
        Rect.fromLTRB(left, top, right, top + painter.height),
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
  });

  final String text;
  final String name;
  final CodeLanguage? language;
  final ValueListenable<int?>? lineSought;

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
  );
}
