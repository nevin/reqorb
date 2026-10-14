import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/code_formatter.dart';
import 'package:reqorb/editor/folding.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/shared/theme.dart';

/// Something the editor offers to write: what the list shows, what goes
/// into the text, and a note on what it is.
typedef Suggestion = ({String label, String insert, String detail});

/// What can be written at the caret: [items] would replace the text from
/// [start] up to the caret.
typedef Suggestions = ({int start, List<Suggestion> items});

/// Works out what can be written at [caret] in [text]. [asked] is true
/// when the list was asked for rather than brought up by typing.
typedef Completer = Suggestions? Function(
  String text,
  int caret, {
  required bool asked,
});

/// What the gutter needs to show code with parts folded away: the number
/// of each shown line, whether it folds (null if not) and is folded, and
/// what to call when the fold on a shown line is tapped.
typedef Folds = ({
  List<int> numbers,
  List<bool?> state,
  ValueChanged<int> toggle,
});

/// A field for code: coloured by language, with numbered lines, matching
/// brackets, find and replace, and completion of `{{variables}}`.
///
/// The text field inside carries [name] as its key; the parts around it
/// are keyed `<name>-gutter`, `<name>-find`, `<name>-find-field`,
/// `<name>-find-count`, `<name>-find-next`, `<name>-find-previous`,
/// `<name>-find-close`, `<name>-replace-toggle`, `<name>-replace-field`,
/// `<name>-replace-one`, `<name>-replace-all` and `<name>-suggestion-<n>`.
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.name,
    required this.controller,
    this.language,
    this.readOnly = false,
    this.hint,
    this.hintLines = 1,
    this.variables = const [],
    this.complete,
    this.folds,
    this.onFind,
    this.findRequests,
    this.onChanged,
  });

  final String name;
  final CodeController controller;

  /// Opens the search each time it notifies, for a button outside.
  final Listenable? findRequests;

  /// Set when the text shown has parts folded away.
  final Folds? folds;

  /// Called as a search opens.
  final VoidCallback? onFind;

  /// Called when the text changes, however it was changed.
  final ValueChanged<String>? onChanged;

  /// What the code is written in; null to go by how it looks.
  final CodeLanguage? language;

  /// For showing code rather than writing it; it can still be selected
  /// and searched.
  final bool readOnly;

  final String? hint;

  /// How many lines of [hint] to show. One, unless the editor is sure of
  /// its height: more could spill out of a pane cut short by the
  /// on-screen keyboard.
  final int hintLines;

  /// Names offered after `{{`.
  final List<String> variables;

  /// What else can be completed, beyond variables.
  final Completer? complete;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _field = GlobalKey();
  final _row = GlobalKey();
  late final _formatter = CodeFormatter(
    // Text nobody has labelled may yet turn out to be code.
    pairs: () => widget.language?.bracketed ?? true,
  );

  // Search.
  bool _finding = false;
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  bool _replacing = false;
  final _replacement = TextEditingController();
  final _replaceFocus = FocusNode();

  /// Where the gutter last drew each line, for finding the one tapped.
  final _drawn = <(int, Rect)>[];

  // Completion.
  final _popup = OverlayPortalController();
  List<Suggestion> _items = const [];
  int _start = 0;
  int _picked = 0;
  Offset _anchor = Offset.zero;
  double _lineHeight = 18;

  late String _lastText = widget.controller.text;
  EditableTextState? _editableState;

  CodeController get _code => widget.controller;

  @override
  void initState() {
    super.initState();
    _code.language = widget.language;
    _code.addListener(_changed);
    _focus.addListener(_focusChanged);
    widget.findRequests?.addListener(_openFind);
  }

  @override
  void didUpdateWidget(CodeEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      _code.addListener(_changed);
      _lastText = _code.text;
    }
    if (old.findRequests != widget.findRequests) {
      old.findRequests?.removeListener(_openFind);
      widget.findRequests?.addListener(_openFind);
    }
    _code.language = widget.language;
  }

  @override
  void dispose() {
    _code.removeListener(_changed);
    widget.findRequests?.removeListener(_openFind);
    // A search belongs to this view of the text, not to the text.
    _code.forgetMarks();
    _scroll.dispose();
    _focus.dispose();
    _query.dispose();
    _queryFocus.dispose();
    _replacement.dispose();
    _replaceFocus.dispose();
    super.dispose();
  }

  /// The text field's inner state, which knows where every character is.
  EditableTextState? _editable() {
    final known = _editableState;
    if (known != null && known.mounted) return known;
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
        return;
      }
      element.visitChildren(visit);
    }

    _field.currentContext?.visitChildElements(visit);
    return _editableState = found;
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _dismiss();
  }

  void _changed() {
    final text = _code.text;
    if (text == _lastText) {
      // The caret moved: a list for somewhere else no longer applies.
      if (_items.isNotEmpty) {
        final caret = _code.selection.baseOffset;
        if (!_code.selection.isCollapsed || caret < _start) _dismiss();
      }
      return;
    }
    _lastText = text;
    widget.onChanged?.call(text);
    if (_finding) _search(keep: true);
    _suggest();
  }

  // --------------------------------------------------------------- search

  void _openFind({bool replace = false}) {
    widget.onFind?.call();
    if (replace && !widget.readOnly) _replacing = true;
    final selection = _code.selection;
    // Start from what is selected, if it is something one would look for.
    if (selection.isValid && !selection.isCollapsed) {
      final picked = selection.textInside(_code.text);
      if (!picked.contains('\n') && picked.length < 200) _query.text = picked;
    }
    setState(() => _finding = true);
    _queryFocus.requestFocus();
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
    _search();
  }

  void _closeFind() {
    setState(() {
      _finding = false;
      _replacing = false;
    });
    _code.mark(const [], -1);
    _focus.requestFocus();
  }

  /// More matches than anyone steps through; past this they are not
  /// worth the colouring.
  static const _mostMatches = 5000;

  /// Finds the query in the text. With [keep], stays on the match it was
  /// on, as when the text changes under a search.
  void _search({bool keep = false}) {
    final query = _query.text.toLowerCase();
    if (query.isEmpty) {
      _code.mark(const [], -1);
      setState(() {});
      return;
    }
    final text = _code.text.toLowerCase();
    final found = <TextRange>[];
    var at = text.indexOf(query);
    while (at >= 0 && found.length < _mostMatches) {
      found.add(TextRange(start: at, end: at + query.length));
      at = text.indexOf(query, at + query.length);
    }
    var current = -1;
    if (found.isNotEmpty) {
      if (keep && _code.current >= 0) {
        current = _code.current.clamp(0, found.length - 1);
      } else {
        // The first one at or after the caret, or else the first.
        final caret = _code.selection.isValid ? _code.selection.start : 0;
        current = found.indexWhere((range) => range.start >= caret);
        if (current < 0) current = 0;
      }
    }
    _code.mark(found, current);
    setState(() {});
    if (!keep) _reveal();
  }

  void _step(int by) {
    final found = _code.found;
    if (found.isEmpty) return;
    _code.mark(found, (_code.current + by) % found.length);
    setState(() {});
    _reveal();
  }

  /// Scrolls the match the search is on into view.
  void _reveal() {
    final current = _code.current;
    if (current < 0) return;
    final range = _code.found[current];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _editable()?.bringIntoView(TextPosition(offset: range.start));
    });
  }

  /// Puts the replacement where the match the search is on was, and moves
  /// on to the next.
  void _replaceOne() {
    final current = _code.current;
    if (widget.readOnly || current < 0) return;
    final range = _code.found[current];
    final with_ = _replacement.text;
    final after = range.start + with_.length;
    _edit(
      _code.text.replaceRange(range.start, range.end, with_),
      TextSelection.collapsed(offset: after),
    );
    // The search has followed the edit. On to the next match after what
    // was put in, which may itself hold what is being looked for.
    final found = _code.found;
    if (found.isEmpty) return;
    final next = found.indexWhere((match) => match.start >= after);
    _code.mark(found, next < 0 ? 0 : next);
    setState(() {});
    _reveal();
  }

  /// Replaces every match, however many, as one edit.
  void _replaceAll() {
    final query = _query.text.toLowerCase();
    if (widget.readOnly || query.isEmpty) return;
    final text = _code.text;
    final lower = text.toLowerCase();
    final with_ = _replacement.text;
    final next = StringBuffer();
    var from = 0;
    var at = lower.indexOf(query);
    if (at < 0) return;
    while (at >= 0) {
      next
        ..write(text.substring(from, at))
        ..write(with_);
      from = at + query.length;
      at = lower.indexOf(query, from);
    }
    next.write(text.substring(from));
    _edit(next.toString(), const TextSelection.collapsed(offset: 0));
  }

  // ----------------------------------------------------------- completion

  static final _nameChar = RegExp(r'[\w.\-]');

  void _dismiss() {
    if (_items.isEmpty) return;
    _items = const [];
    if (_popup.isShowing) _popup.hide();
  }

  /// Brings up what can be written at the caret, if anything.
  void _suggest({bool asked = false}) {
    final selection = _code.selection;
    if (widget.readOnly ||
        !_focus.hasFocus ||
        !selection.isValid ||
        !selection.isCollapsed) {
      _dismiss();
      return;
    }
    final text = _code.text;
    final caret = selection.baseOffset;

    Suggestions? suggestions;
    // A variable: `{{` and as much of a name as has been typed.
    var start = caret;
    while (start > 0 && _nameChar.hasMatch(text[start - 1])) {
      start--;
    }
    if (start >= 2 && text[start - 1] == '{' && text[start - 2] == '{') {
      final typed = text.substring(start, caret).toLowerCase();
      final closed = text.startsWith('}}', caret);
      final names = widget.variables
          .where((name) => name.toLowerCase().contains(typed))
          .toSet()
          .toList();
      // Names starting with what was typed come before ones containing it.
      final first = names.where((n) => n.toLowerCase().startsWith(typed));
      final rest = names.where((n) => !n.toLowerCase().startsWith(typed));
      suggestions = (
        start: start,
        items: [
          for (final name in [...first, ...rest])
            (
              label: name,
              insert: closed ? name : '$name}}',
              detail: 'variable',
            ),
        ],
      );
    } else {
      suggestions = widget.complete?.call(text, caret, asked: asked);
    }

    final items = suggestions?.items ?? const <Suggestion>[];
    final from = suggestions?.start ?? caret;
    // Nothing to offer, or only what is already written.
    if (items.isEmpty ||
        (items.length == 1 && items[0].label == text.substring(from, caret))) {
      _dismiss();
      return;
    }
    _items = items.length > 50 ? items.sublist(0, 50) : items;
    _start = from;
    _picked = 0;
    // Placed once the text has been laid out with the edit in it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
    WidgetsBinding.instance.scheduleFrame();
  }

  void _place() {
    if (!mounted || _items.isEmpty) return;
    final editable = _editable()?.renderEditable;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (editable == null || !editable.attached || overlay is! RenderBox) return;
    final at = _start.clamp(0, _code.text.length);
    final caret = editable.getLocalRectForCaret(TextPosition(offset: at));
    setState(() {
      _anchor = overlay.globalToLocal(editable.localToGlobal(caret.topLeft));
      _lineHeight = caret.height;
    });
    if (!_popup.isShowing) _popup.show();
  }

  void _accept(int index) {
    final item = _items[index];
    final caret = _code.selection.baseOffset;
    final text = _code.text;
    final start = _start.clamp(0, caret);
    _dismiss();
    final next = text.replaceRange(start, caret, item.insert);
    _lastText = next;
    widget.onChanged?.call(next);
    _code.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + item.insert.length),
    );
    _focus.requestFocus();
  }

  // ------------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;

    if (command && key == LogicalKeyboardKey.keyF) {
      _openFind(replace: keyboard.isAltPressed);
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
    if (!_focus.hasFocus) return KeyEventResult.ignored;

    if (_items.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp) {
        final by = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
        setState(() => _picked = (_picked + by) % _items.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.tab) {
        _accept(_picked);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        setState(_dismiss);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape && _finding) {
      _closeFind();
      return KeyEventResult.handled;
    }
    if (widget.readOnly) return KeyEventResult.ignored;
    if (keyboard.isControlPressed && key == LogicalKeyboardKey.space) {
      _suggest(asked: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab && !command && !keyboard.isAltPressed) {
      _indent(outdent: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Tab: indents at the caret, or every line of a selection that spans
  /// lines. With [outdent], takes one level off instead.
  void _indent({required bool outdent}) {
    final selection = _code.selection;
    if (!selection.isValid) return;
    final text = _code.text;
    final unit = CodeStyle.indent;
    final start = selection.start;
    final end = selection.end;
    final several = text.substring(start, end).contains('\n');
    if (!outdent && !several) {
      _edit(
        text.replaceRange(start, end, unit),
        TextSelection.collapsed(offset: start + unit.length),
      );
      return;
    }
    final first = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    final lines = text.substring(first, end).split('\n');
    var firstShift = 0;
    var shift = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      var by = 0;
      if (!outdent) {
        if (line.isNotEmpty) {
          lines[i] = unit + line;
          by = unit.length;
        }
      } else if (line.startsWith(unit)) {
        lines[i] = line.substring(unit.length);
        by = -unit.length;
      } else if (line.startsWith('\t') || line.startsWith(' ')) {
        final kept = line.replaceFirst(
          RegExp(
            r'^(\t| {1,'
            '${unit.length}'
            r'})',
          ),
          '',
        );
        by = kept.length - line.length;
        lines[i] = kept;
      }
      if (i == 0) firstShift = by;
      shift += by;
    }
    int moved(int offset, int by) => offset + by < first ? first : offset + by;
    _edit(
      text.replaceRange(first, end, lines.join('\n')),
      TextSelection(
        baseOffset: moved(start, firstShift),
        extentOffset: moved(end, shift),
      ),
    );
  }

  void _edit(String text, TextSelection selection) {
    _code.value = TextEditingValue(text: text, selection: selection);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = mono;
    final name = widget.name;

    final field = TextField(
      key: Key(name),
      controller: _code,
      focusNode: _focus,
      scrollController: _scroll,
      readOnly: widget.readOnly,
      // A read-only field still takes the caret keys, to select with.
      showCursor: !widget.readOnly,
      maxLines: null,
      expands: true,
      autocorrect: false,
      enableSuggestions: false,
      smartQuotesType: SmartQuotesType.disabled,
      smartDashesType: SmartDashesType.disabled,
      textAlignVertical: TextAlignVertical.top,
      inputFormatters: widget.readOnly ? null : [_formatter],
      style: style,
      decoration: InputDecoration(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.fromLTRB(8, 12, 12, 12),
        hintText: widget.hint,
        hintMaxLines: widget.hintLines,
      ),
    );

    final gutterStyle = style.copyWith(
      color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
    );
    final digit = (TextPainter(
      text: TextSpan(text: '0', style: gutterStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout()).width;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: OverlayPortal(
        controller: _popup,
        overlayChildBuilder: _suggestions,
        child: Stack(
          children: [
            // Rebuilt when the pane is resized, so the numbers follow the
            // lines as they wrap differently.
            LayoutBuilder(
              builder: (context, constraints) => ListenableBuilder(
                listenable: _code,
                builder: (context, _) {
                  final lines = '\n'.allMatches(_code.text).length + 1;
                  final folds = widget.folds;
                  final last = folds == null || folds.numbers.isEmpty
                      ? lines
                      : folds.numbers.last;
                  final digits = last.toString().length.clamp(2, 9);
                  return Row(
                    key: _row,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GestureDetector(
                        key: Key('$name-gutter'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: folds == null
                            ? null
                            : (tap) => _tapGutter(tap.localPosition.dy),
                        child: SizedBox(
                          width: digit * digits + (folds == null ? 14 : 28),
                          child: CustomPaint(
                            painter: _Gutter(
                              folds: folds,
                              drawn: _drawn,
                              code: _code,
                              scroll: _scroll,
                              editable: () => _editable()?.renderEditable,
                              row: () =>
                                  _row.currentContext?.findRenderObject(),
                              style: gutterStyle,
                              currentColor: scheme.onSurface,
                              textScaler: MediaQuery.textScalerOf(context),
                              width: constraints.maxWidth,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: KeyedSubtree(key: _field, child: field),
                      ),
                    ],
                  );
                },
              ),
            ),
            Positioned(
              top: 4,
              right: 6,
              child: _finding ? _findBar(theme) : _findButton(scheme),
            ),
          ],
        ),
      ),
    );
  }

  void _tapGutter(double y) {
    final folds = widget.folds;
    if (folds == null) return;
    for (final (line, rect) in _drawn) {
      if (y < rect.top || y >= rect.bottom) continue;
      if (line < folds.state.length && folds.state[line] != null) {
        folds.toggle(line);
      }
      return;
    }
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
    final found = _code.found;
    final none = _query.text.isNotEmpty && found.isEmpty;
    final compact = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 28),
      textStyle: theme.textTheme.labelMedium,
    );
    Widget button(
      String key,
      String tip,
      IconData icon,
      VoidCallback? onTap, {
      String? at,
    }) => IconButton(
      key: Key(at ?? '$name-find-$key'),
      tooltip: tip,
      iconSize: 16,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      icon: Icon(icon),
      onPressed: onTap,
    );
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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.readOnly)
                  button(
                    'toggle',
                    _replacing
                        ? 'Hide replace'
                        : 'Replace ($shortcutModifier⌥F)',
                    _replacing ? Icons.expand_more : Icons.chevron_right,
                    () => setState(() => _replacing = !_replacing),
                    at: '$name-replace-toggle',
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
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 6),
                      hintText: 'Find',
                    ),
                    onChanged: (_) => _search(),
                    // Stays in the field, ready for the next one.
                    onEditingComplete: () => _step(1),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    found.isEmpty
                        ? (none ? 'None' : '')
                        : '${_code.current + 1} of ${found.length}'
                              '${found.length >= _mostMatches ? '+' : ''}',
                    key: Key('$name-find-count'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: none ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                button(
                  'previous',
                  'Previous (⇧Enter)',
                  Icons.keyboard_arrow_up,
                  found.isEmpty ? null : () => _step(-1),
                ),
                button(
                  'next',
                  'Next (Enter)',
                  Icons.keyboard_arrow_down,
                  found.isEmpty ? null : () => _step(1),
                ),
                button('close', 'Close (Esc)', Icons.close, _closeFind),
              ],
            ),
            if (_replacing && !widget.readOnly)
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
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                        hintText: 'Replace with',
                      ),
                      onEditingComplete: _replaceOne,
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton(
                    key: Key('$name-replace-one'),
                    style: compact,
                    onPressed: found.isEmpty ? null : _replaceOne,
                    child: const Text('Replace'),
                  ),
                  TextButton(
                    key: Key('$name-replace-all'),
                    style: compact,
                    onPressed: found.isEmpty ? null : _replaceAll,
                    child: const Text('All'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _suggestions(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const width = 280.0;
    const row = 30.0;
    final shown = _items.length < 7 ? _items.length : 7;
    final height = shown * row + 8;
    final screen = MediaQuery.sizeOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    // Below the line, unless there is only room above it.
    final below = _anchor.dy + _lineHeight + 2;
    final fits = below + height <= screen.height - insets.bottom - 4;
    final top = fits ? below : _anchor.dy - height - 2;
    final left = _anchor.dx.clamp(
      4.0,
      (screen.width - width - 4).clamp(4.0, double.infinity),
    );
    return Positioned(
      left: left,
      top: top < 4 ? 4 : top,
      width: width,
      height: height,
      // Counts as part of the field, so a click on it keeps the caret.
      child: TextFieldTapRegion(
        child: Material(
          elevation: 6,
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: _SuggestionList(
            name: widget.name,
            items: _items,
            picked: _picked,
            rowHeight: row,
            onPick: _accept,
          ),
        ),
      ),
    );
  }
}

class _SuggestionList extends StatefulWidget {
  const _SuggestionList({
    required this.name,
    required this.items,
    required this.picked,
    required this.rowHeight,
    required this.onPick,
  });

  final String name;
  final List<Suggestion> items;
  final int picked;
  final double rowHeight;
  final ValueChanged<int> onPick;

  @override
  State<_SuggestionList> createState() => _SuggestionListState();
}

class _SuggestionListState extends State<_SuggestionList> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_SuggestionList old) {
    super.didUpdateWidget(old);
    if (old.picked == widget.picked || !_scroll.hasClients) return;
    // Keeps the one picked with the arrow keys in sight.
    final top = widget.picked * widget.rowHeight;
    final view = _scroll.position.viewportDimension - 8;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + widget.rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + widget.rowHeight - view);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemExtent: widget.rowHeight,
      itemCount: widget.items.length,
      itemBuilder: (context, index) {
        final item = widget.items[index];
        return InkWell(
          key: Key('${widget.name}-suggestion-$index'),
          canRequestFocus: false,
          onTap: () => widget.onPick(index),
          child: Container(
            color: index == widget.picked
                ? scheme.primary.withValues(alpha: 0.16)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono.copyWith(fontSize: 12.5),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.detail,
                    maxLines: 1,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The line numbers beside the text. Asks the text itself where each line
/// is, so the numbers stay with their lines however those wrap.
class _Gutter extends CustomPainter {
  _Gutter({
    required this.folds,
    required this.drawn,
    required this.code,
    required this.scroll,
    required this.editable,
    required this.row,
    required this.style,
    required this.currentColor,
    required this.textScaler,
    required this.width,
  }) : super(repaint: Listenable.merge([code, scroll]));

  final Folds? folds;

  /// Filled with each line drawn and where, for whoever handles taps.
  final List<(int, Rect)> drawn;
  final CodeController code;
  final ScrollController scroll;
  final RenderEditable? Function() editable;

  /// The row the gutter and the field share, to measure the field from.
  final RenderObject? Function() row;
  final TextStyle style;
  final Color currentColor;
  final TextScaler textScaler;

  /// How wide the editor is; a change means the lines wrap anew.
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    drawn.clear();
    final folds = this.folds;
    final editable = this.editable();
    if (editable == null || !editable.attached || !editable.hasSize) return;
    final text = code.text;

    // Where each line starts in the text.
    final starts = <int>[0];
    for (
      var at = text.indexOf('\n');
      at >= 0;
      at = text.indexOf('\n', at + 1)
    ) {
      starts.add(at + 1);
    }

    // The field sits a little below the top of the gutter, by its padding.
    final row = this.row();
    final inset = row == null
        ? 12.0
        : editable.localToGlobal(Offset.zero, ancestor: row).dy;
    Rect lineAt(int index) => editable
        .getLocalRectForCaret(TextPosition(offset: starts[index]))
        .shift(Offset(0, inset));

    // The first line that reaches into view.
    var low = 0, high = starts.length - 1;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (lineAt(mid).bottom < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }

    final selection = code.selection;
    final caret = selection.isValid ? selection.extentOffset : -1;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var line = low; line < starts.length; line++) {
      final rect = lineAt(line);
      if (rect.top > size.height) break;
      final end = line + 1 < starts.length ? starts[line + 1] : text.length + 1;
      final current = caret >= starts[line] && caret < end;
      drawn.add((line, rect));
      final shown = folds != null && line < folds.numbers.length
          ? folds.numbers[line]
          : line + 1;
      final folded = folds != null && line < folds.state.length
          ? folds.state[line]
          : null;
      if (folded != null) {
        // A small arrow: down over what is open, sideways at what is shut.
        final centre = Offset(size.width - 9, rect.center.dy);
        final arrow = Path();
        if (folded) {
          arrow
            ..moveTo(centre.dx - 2, centre.dy - 4)
            ..lineTo(centre.dx + 3, centre.dy)
            ..lineTo(centre.dx - 2, centre.dy + 4);
        } else {
          arrow
            ..moveTo(centre.dx - 4, centre.dy - 2)
            ..lineTo(centre.dx, centre.dy + 3)
            ..lineTo(centre.dx + 4, centre.dy - 2);
        }
        canvas.drawPath(
          arrow..close(),
          Paint()..color = folded ? currentColor : style.color!,
        );
      }
      final number = TextPainter(
        text: TextSpan(
          text: '$shown',
          style: current ? style.copyWith(color: currentColor) : style,
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      number.paint(
        canvas,
        Offset(
          size.width - number.width - (folds == null ? 6 : 20),
          rect.top + (rect.height - number.height) / 2,
        ),
      );
      number.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Gutter old) =>
      old.code != code ||
      old.folds != folds ||
      old.style != style ||
      old.currentColor != currentColor ||
      old.width != width ||
      old.textScaler != textScaler;
}

/// Code to read rather than write: coloured, numbered, and searchable.
class CodeView extends StatefulWidget {
  const CodeView({
    super.key,
    required this.name,
    required this.text,
    this.language,
    this.findRequests,
    this.onLink,
  });

  final String name;
  final String text;
  final CodeLanguage? language;

  /// Called with a web address in the text when it is clicked.
  final ValueChanged<Uri>? onLink;

  /// Opens the search each time it notifies.
  final Listenable? findRequests;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  late final _code = CodeController(text: widget.text, onLink: widget.onLink);
  List<FoldRegion> _regions = const [];
  final _folded = <int>{};
  FoldedText? _shown;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(CodeView old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.language != widget.language) {
      _folded.clear();
      _measure();
      _code.text = widget.text;
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// Finds what can be folded in the text.
  void _measure() {
    final text = widget.text;
    final language = widget.language ?? CodeLanguage.sniff(text);
    _regions = text.length > highlightLimit || !folds(language)
        ? const []
        : foldRegions(text, tokenize(text, language));
    _shown = _regions.isEmpty ? null : foldText(text, _regions, _folded);
  }

  void _toggle(int line) {
    final open = _shown!.opens[line];
    if (open < 0) return;
    if (!_folded.remove(open)) _folded.add(open);
    _show();
  }

  void _show() {
    setState(() => _shown = foldText(widget.text, _regions, _folded));
    _code.text = _shown!.text;
  }

  /// A search looks through everything, folded or not.
  void _unfold() {
    if (_folded.isEmpty) return;
    _folded.clear();
    _show();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return CodeEditor(
      name: widget.name,
      controller: _code,
      language: widget.language,
      readOnly: true,
      folds: shown == null
          ? null
          : (numbers: shown.numbers, state: shown.folds, toggle: _toggle),
      onFind: _unfold,
      findRequests: widget.findRequests,
    );
  }
}

/// A [CodeEditor] of a fixed height with a border round it, for a form.
class CodeBox extends StatelessWidget {
  const CodeBox({super.key, required this.height, required this.child});

  final double height;
  final CodeEditor child;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(6),
    ),
    child: child,
  );
}
