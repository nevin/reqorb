/// A row of tabs that, when it is too narrow for them all, says so with a
/// button that lists every tab.
library;

import 'package:flutter/material.dart';

/// One tab: its key, and what it shows.
typedef TabEntry = ({Key key, Widget label});

/// A scrolling [TabBar] for the nearest [DefaultTabController], with a
/// button at its end, shown only while some tabs are out of sight, that
/// lists them all and goes to the one chosen.
class OverflowTabBar extends StatefulWidget {
  const OverflowTabBar({super.key, required this.tabs, this.height = 40});

  final List<TabEntry> tabs;
  final double height;

  @override
  State<OverflowTabBar> createState() => _OverflowTabBarState();
}

class _OverflowTabBarState extends State<OverflowTabBar> {
  bool _overflows = false;

  bool _measure(ScrollMetricsNotification notification) {
    final overflows = notification.metrics.maxScrollExtent > 0;
    if (overflows != _overflows) {
      // Told during layout, so changed after it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _overflows = overflows);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    return Row(
      children: [
        Expanded(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: _measure,
            child: TabBar(
              // Tabs sit together at the start instead of stretching out.
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final tab in widget.tabs)
                  Tab(key: tab.key, height: widget.height, child: tab.label),
              ],
            ),
          ),
        ),
        if (_overflows)
          PopupMenuButton<int>(
            key: const Key('more-tabs'),
            tooltip: 'All sections',
            icon: const Icon(Icons.expand_more, size: 20),
            initialValue: controller.index,
            onSelected: controller.animateTo,
            itemBuilder: (_) => [
              for (final (i, tab) in widget.tabs.indexed)
                PopupMenuItem(value: i, child: tab.label),
            ],
          ),
      ],
    );
  }
}
