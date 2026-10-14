import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/shared/theme.dart';

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

  /// The longest line, in characters, which sets how far it scrolls
  /// across; past [_widest] a line is cut short.
  int _longest = 0;
  static const _widest = 2000;

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
    var at = 0;
    var longest = 0;
    for (var i = 0; i < _lines.length; i++) {
      starts[i] = at;
      at += _lines[i].length + 1;
      longest = math.max(longest, _lines[i].length);
    }
    _starts = starts;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients) return;
      final position = _vertical.position;
      // A few lines above it, for context.
      position.jumpTo(
        ((low - 3) * _lineHeight).clamp(0, position.maxScrollExtent),
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
                itemCount: _lines.length,
                itemBuilder: (_, index) {
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
                              '${index + 1}',
                              textAlign: TextAlign.right,
                              style: numbers,
                            ),
                          ),
                        ),
                        SizedBox(width: CodeStyle.fontSize),
                        Expanded(
                          child: Text(
                            line.length > _widest
                                ? '${line.substring(0, _widest)}…'
                                : line,
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
