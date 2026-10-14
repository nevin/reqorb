/// Two panes with a divider that can be dragged.
library;

import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';

/// Where the response goes for a [layout] setting in a pane [width] wide:
/// beside the request ([Axis.horizontal]) or below it.
Axis responseAxis(Layout layout, double width) => switch (layout) {
  Layout.sideBySide => Axis.horizontal,
  Layout.stacked => Axis.vertical,
  // Side by side when there is room, stacked otherwise.
  Layout.auto => width >= 900 ? Axis.horizontal : Axis.vertical,
};

/// Two panes with a divider between them that can be dragged to resize.
/// The divider carries a grip, so that it is seen to be something to drag.
class SplitView extends StatefulWidget {
  const SplitView({
    super.key,
    required this.axis,
    required this.fraction,
    required this.onChanged,
    this.onChangeEnd,
    required this.first,
    required this.second,
  });

  final Axis axis;

  /// Share of the space given to [first].
  final double fraction;
  final ValueChanged<double> onChanged;

  /// Called with where the divider was left, once a drag ends.
  final ValueChanged<double>? onChangeEnd;
  final Widget first;
  final Widget second;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  /// Whether the pointer is over the divider, or dragging it.
  bool _hover = false;
  bool _dragging = false;

  /// Where the current drag has taken the divider.
  double? _moved;

  // A finger needs more to take hold of than a pointer does.
  static final _handle = isDesktop ? 11.0 : 22.0;
  static const _minPane = 120.0;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final scheme = Theme.of(context).colorScheme;
    final active = _hover || _dragging;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total =
            (horizontal ? constraints.maxWidth : constraints.maxHeight) -
            _handle;
        var size = total * widget.fraction;
        // Neither pane may be dragged out of reach.
        if (total > _minPane * 2) {
          size = size.clamp(_minPane, total - _minPane);
        }
        final line = AnimatedContainer(
          // A line that turns from lying to standing is another line, not
          // one to be animated between the two.
          key: ValueKey(horizontal),
          duration: const Duration(milliseconds: 120),
          width: horizontal ? (active ? 2 : 1) : null,
          height: horizontal ? null : (active ? 2 : 1),
          color: active ? scheme.primary : scheme.outlineVariant,
        );
        final grip = AnimatedContainer(
          key: const Key('split-grip'),
          duration: const Duration(milliseconds: 120),
          width: horizontal ? 5 : 40,
          height: horizontal ? 40 : 5,
          decoration: BoxDecoration(
            color: active ? scheme.primary : scheme.outline,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: scheme.surface),
          ),
        );
        return Flex(
          direction: widget.axis,
          children: [
            SizedBox(
              width: horizontal ? size : null,
              height: horizontal ? null : size,
              child: widget.first,
            ),
            MouseRegion(
              cursor: horizontal
                  ? SystemMouseCursors.resizeColumn
                  : SystemMouseCursors.resizeRow,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: Tooltip(
                message: 'Drag to resize; double-click to reset',
                waitDuration: const Duration(milliseconds: 700),
                child: GestureDetector(
                  key: const Key('split-handle'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => setState(() => _dragging = true),
                  onPanEnd: (_) {
                    setState(() => _dragging = false);
                    // The last move may not have been built yet.
                    widget.onChangeEnd?.call(_moved ?? widget.fraction);
                    _moved = null;
                  },
                  onPanCancel: () => setState(() => _dragging = false),
                  onPanUpdate: (drag) {
                    if (total <= 0) return;
                    final moved = horizontal ? drag.delta.dx : drag.delta.dy;
                    // From where the last move left it, built or not.
                    final from = (_moved ?? widget.fraction) * total;
                    _moved = ((from + moved) / total).clamp(0.1, 0.9);
                    widget.onChanged(_moved!);
                  },
                  onDoubleTap: () {
                    widget.onChanged(0.4);
                    widget.onChangeEnd?.call(0.4);
                  },
                  child: SizedBox(
                    width: horizontal ? _handle : null,
                    height: horizontal ? null : _handle,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [line, grip],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: widget.second),
          ],
        );
      },
    );
  }
}
