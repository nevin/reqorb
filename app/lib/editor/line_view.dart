import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/shared/theme.dart';

/// The longest text, in characters, shown in an editor; longer text is
/// shown in a [LineView]. An editor lays out all its text again on each
/// change: at a megabyte that takes half a second, and at ten, ten seconds
/// or more.
const editLimit = 1024 * 1024;

/// Text too long for an editor, shown read-only a line at a time: only
/// the lines in view are built, so it opens at once whatever its length.
/// It follows [CodeController.goToLine] on [controller], as the editor
/// does.
class LineView extends StatefulWidget {
  const LineView({super.key, required this.controller});

  final CodeController controller;

  @override
  State<LineView> createState() => _LineViewState();
}

class _LineViewState extends State<LineView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  late String _text;
  List<String> _lines = const [];

  /// Where each line starts in the text, to find the line of an offset.
  List<int> _starts = const [];

  /// A line longer than [_widest] goes on over more rows, without a
  /// number, as minified JSON does. For each row, its line and where in
  /// the line it starts; for each line, its first row.
  Int32List _rowLine = Int32List(0);
  Int32List _rowFrom = Int32List(0);
  Int32List _firstRow = Int32List(0);
  static const _widest = 2000;

  /// The longest row, in characters, which sets how far it scrolls across.
  int _longest = 0;

  /// The line [CodeController.goToLine] asked for, shown marked.
  int? _sought;

  @override
  void initState() {
    super.initState();
    _split();
    widget.controller.addListener(_changed);
    widget.controller.lineSought.addListener(_goToLine);
  }

  @override
  void didUpdateWidget(LineView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      old.controller.lineSought.removeListener(_goToLine);
      widget.controller.addListener(_changed);
      widget.controller.lineSought.addListener(_goToLine);
      _split();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.lineSought.removeListener(_goToLine);
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _split() {
    _text = widget.controller.text;
    _lines = _text.split('\n');
    final starts = List<int>.filled(_lines.length, 0);
    final firstRow = Int32List(_lines.length);
    var rows = 0;
    var at = 0;
    var longest = 0;
    for (var i = 0; i < _lines.length; i++) {
      final length = _lines[i].length;
      starts[i] = at;
      at += length + 1;
      longest = math.max(longest, length);
      firstRow[i] = rows;
      rows += length <= _widest ? 1 : (length + _widest - 1) ~/ _widest;
    }
    final rowLine = Int32List(rows);
    final rowFrom = Int32List(rows);
    for (var i = 0, row = 0; i < _lines.length; i++) {
      var from = 0;
      do {
        rowLine[row] = i;
        rowFrom[row] = from;
        row++;
        from += _widest;
      } while (from < _lines[i].length);
    }
    _starts = starts;
    _rowLine = rowLine;
    _rowFrom = rowFrom;
    _firstRow = firstRow;
    _longest = math.min(longest, _widest);
    _sought = null;
  }

  /// The text was replaced, as when it is converted to JSON.
  void _changed() {
    if (widget.controller.text == _text) return;
    setState(_split);
  }

  void _goToLine() {
    final offset = widget.controller.lineSought.value;
    if (offset == null) return;
    // The last line that starts at or before the offset.
    var low = 0;
    var high = _starts.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_starts[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    setState(() => _sought = low);
    final row = _firstRow[low];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients) return;
      final position = _vertical.position;
      // A few rows above it, for context.
      position.jumpTo(
        ((row - 3) * _lineHeight).clamp(0, position.maxScrollExtent),
      );
    });
  }

  double get _lineHeight => CodeStyle.fontSize * 1.4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = mono;
    final numbers = style.copyWith(color: scheme.outline);
    final digits = '${_lines.length}'.length;
    final gutter = (digits + 2) * CodeStyle.fontSize * 0.62;
    final width = gutter + (_longest + 2) * CodeStyle.fontSize * 0.62;
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
            child: SelectionArea(
              child: ListView.builder(
                key: const Key('line-view'),
                controller: _vertical,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemExtent: _lineHeight,
                itemCount: _rowLine.length,
                itemBuilder: (_, row) {
                  final index = _rowLine[row];
                  final from = _rowFrom[row];
                  final line = _lines[index];
                  return ColoredBox(
                    color: index == _sought
                        ? scheme.primaryContainer
                        : Colors.transparent,
                    child: Row(
                      children: [
                        SizedBox(
                          width: gutter,
                          child: SelectionContainer.disabled(
                            child: Text(
                              from == 0 ? '${index + 1}' : '',
                              textAlign: TextAlign.right,
                              style: numbers,
                            ),
                          ),
                        ),
                        SizedBox(width: CodeStyle.fontSize),
                        Expanded(
                          child: Text(
                            line.length <= _widest
                                ? line
                                : line.substring(
                                    from,
                                    math.min(from + _widest, line.length),
                                  ),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            style: style,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
