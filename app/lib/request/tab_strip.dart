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
  });

  final List<OpenTab> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNew;

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
  });

  final int index;
  final OpenTab tab;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: '${tab.method} ${tab.name}',
      selected: active,
      button: true,
      child: InkWell(
        key: Key('tab-$index'),
        onTap: onSelect,
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
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                color: scheme.onSurfaceVariant,
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
