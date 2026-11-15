import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';

/// What the strip shows for one open request.
typedef OpenTab = ({String method, String name, bool dirty});

/// The row of open requests above the editor.
class TabStrip extends StatelessWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onCloseOthers,
    required this.onCloseAfter,
    required this.onDuplicate,
    required this.onReopen,
    required this.onMove,
  });

  final List<OpenTab> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNew;

  /// Closes every tab but the one given.
  final ValueChanged<int> onCloseOthers;

  /// Closes the tabs to the right of the one given.
  final ValueChanged<int> onCloseAfter;

  /// Opens a copy of the tab given, as a request not yet saved.
  final ValueChanged<int> onDuplicate;

  /// Opens the tab closed last again; null when none has been closed.
  final VoidCallback? onReopen;

  /// Puts the first tab where the second is, when one is dragged there.
  final void Function(int from, int to) onMove;

  /// What can be done with the tab at [index], offered where it was
  /// right-clicked or held.
  void _menu(BuildContext context, int index, Offset at) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          key: const Key('tab-menu-close'),
          value: () => onClose(index),
          child: Text('Close (${shortcutModifier}W)'),
        ),
        PopupMenuItem(
          key: const Key('tab-menu-close-others'),
          enabled: tabs.length > 1,
          value: () => onCloseOthers(index),
          child: const Text('Close others'),
        ),
        PopupMenuItem(
          key: const Key('tab-menu-close-after'),
          enabled: index < tabs.length - 1,
          value: () => onCloseAfter(index),
          child: const Text('Close tabs to the right'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          key: const Key('tab-menu-duplicate'),
          value: () => onDuplicate(index),
          child: const Text('Duplicate'),
        ),
        PopupMenuItem(
          key: const Key('tab-menu-reopen'),
          enabled: onReopen != null,
          value: onReopen,
          child: Text('Reopen closed tab (⇧${shortcutModifier}T)'),
        ),
      ],
    ).then((action) => action?.call());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (index, tab) in tabs.indexed)
                    _Tab(
                      index: index,
                      tab: tab,
                      active: index == active,
                      onSelect: () => onSelect(index),
                      onClose: () => onClose(index),
                      onMenu: (at) => _menu(context, index, at),
                      onDropped: (from) => onMove(from, index),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            key: const Key('tab-new'),
            tooltip: 'New request (${shortcutModifier}N)',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: scheme.onSurfaceVariant,
            icon: const Icon(Icons.add),
            onPressed: onNew,
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.index,
    required this.tab,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onMenu,
    required this.onDropped,
  });

  final int index;
  final OpenTab tab;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  /// Shows the tab's menu at a place in the window.
  final ValueChanged<Offset> onMenu;

  /// Called with the place of a tab dropped on this one.
  final ValueChanged<int> onDropped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // With a pointer a tab is dragged to another's place. A finger holds a
    // tab for its menu instead.
    if (!isDesktop) return _label(context);
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => onDropped(details.data),
      builder: (context, over, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 2,
              color: over.isEmpty ? Colors.transparent : scheme.primary,
            ),
          ),
        ),
        child: Draggable<int>(
          data: index,
          axis: Axis.horizontal,
          feedback: Material(
            elevation: 4,
            color: scheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Text('${tab.method}  ${tab.name}'),
            ),
          ),
          child: _label(context),
        ),
      ),
    );
  }

  Widget _label(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: '${tab.method} ${tab.name}',
      selected: active,
      button: true,
      // The middle button closes a tab, as in a browser.
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) onClose();
        },
        child: InkWell(
          key: Key('tab-$index'),
          onTap: onSelect,
          onSecondaryTapUp: (details) => onMenu(details.globalPosition),
          onLongPress: () {
            final box = context.findRenderObject()! as RenderBox;
            onMenu(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
          },
          child: Container(
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.only(left: 12, right: 2),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  width: 2,
                  color: active ? scheme.primary : Colors.transparent,
                ),
                right: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: RichText(
                    text: TextSpan(
                      text: tab.method,
                      style: mono.copyWith(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: methodColor(tab.method, scheme.brightness),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  // Drawn directly, as a label and not as text in the page:
                  // the request's name is already on show in the title.
                  child: ExcludeSemantics(
                    child: RichText(
                      key: Key('tab-name-$index'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        text: tab.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 13,
                          color: active
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                if (tab.dirty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.circle,
                      key: Key('tab-dirty-$index'),
                      size: 7,
                      color: scheme.primary,
                    ),
                  ),
                IconButton(
                  key: Key('tab-close-$index'),
                  tooltip: 'Close (${shortcutModifier}W)',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  color: scheme.onSurfaceVariant,
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
