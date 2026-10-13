/// Two panes with a divider that can be dragged.
library;

import 'package:flutter/material.dart';
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
class SplitView extends StatelessWidget {
  const SplitView({
    super.key,
    required this.axis,
    required this.fraction,
    required this.onChanged,
    required this.first,
    required this.second,
  });

  final Axis axis;

  /// Share of the space given to [first].
  final double fraction;
  final ValueChanged<double> onChanged;
  final Widget first;
  final Widget second;

  static const _handle = 7.0;
  static const _minPane = 120.0;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total =
            (horizontal ? constraints.maxWidth : constraints.maxHeight) -
            _handle;
        var size = total * fraction;
        // Neither pane may be dragged out of reach.
        if (total > _minPane * 2) {
          size = size.clamp(_minPane, total - _minPane);
        }
        final line = horizontal
            ? const VerticalDivider(width: 1)
            : const Divider(height: 1);
        return Flex(
          direction: axis,
          children: [
            SizedBox(
              width: horizontal ? size : null,
              height: horizontal ? null : size,
              child: first,
            ),
            MouseRegion(
              cursor: horizontal
                  ? SystemMouseCursors.resizeColumn
                  : SystemMouseCursors.resizeRow,
              child: GestureDetector(
                key: const Key('split-handle'),
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (drag) {
                  if (total <= 0) return;
                  final moved = horizontal ? drag.delta.dx : drag.delta.dy;
                  onChanged(((size + moved) / total).clamp(0.1, 0.9));
                },
                onDoubleTap: () => onChanged(0.4),
                child: SizedBox(
                  width: horizontal ? _handle : null,
                  height: horizontal ? null : _handle,
                  child: Center(child: line),
                ),
              ),
            ),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}
