/// The app's menus behind one button, for platforms with no menu bar of
/// their own. They hold what the Mac's menu bar holds.
library;

import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';

/// One entry: what it says, the command it asks for, and the keys that do
/// the same, written for a Mac. A null entry is a dividing line.
typedef _Entry = (String label, String command, String keys);

const _menus = <(String, List<_Entry?>)>[
  (
    'File',
    [
      ('New request', 'newRequest', '⌘N'),
      ('New collection…', 'newCollection', ''),
      null,
      ('Open file…', 'openFile', '⌘O'),
      ('Open collection folder…', 'openFolder', ''),
      ('Import a file…', 'importFile', ''),
      ('Import from a URL…', 'importUrl', ''),
      ('Paste curl or JSON…', 'importPaste', ''),
      null,
      ('Save request', 'save', '⌘S'),
      null,
      ('Duplicate tab', 'duplicateTab', ''),
      ('Close tab', 'closeTab', '⌘W'),
      ('Reopen closed tab', 'reopenTab', '⇧⌘T'),
    ],
  ),
  (
    'View',
    [
      ('Show or hide sidebar', 'sidebar', '⌘B'),
      ('Find anything…', 'palette', '⌘K'),
      null,
      ('Larger code', 'zoomIn', '⌘+'),
      ('Smaller code', 'zoomOut', '⌘-'),
      ('Usual size', 'zoomReset', '⌘0'),
      null,
      ('Next tab', 'nextTab', '⌃Tab'),
      ('Previous tab', 'previousTab', '⌃⇧Tab'),
    ],
  ),
  (
    'Request',
    [
      ('Send', 'send', '⌘↵'),
      ('Stop', 'stop', '⌘.'),
      null,
      ('Go to address', 'focusUrl', '⌘L'),
      ('Show as code…', 'code', ''),
      null,
      ('Environments…', 'environments', ''),
    ],
  ),
  (
    'Tools',
    [
      ('History', 'history', ''),
      ('API specs', 'specs', ''),
      ('HAR analyser…', 'har', ''),
      null,
      ('Settings…', 'settings', ''),
    ],
  ),
  ('Help', [('Keyboard shortcuts', 'shortcuts', '⌘/')]),
];

/// The keys as they are written on this platform.
String _keys(String keys) => shortcutModifier == '⌘'
    ? keys
    : keys
          .replaceAll('⌃⇧', 'Ctrl+Shift+')
          .replaceAll('⇧⌘', 'Ctrl+Shift+')
          .replaceAll('⌘', 'Ctrl+')
          .replaceAll('⌃', 'Ctrl+')
          .replaceAll('↵', 'Enter');

/// A button that opens the app's menus, each doing one of [commands] by
/// name.
class AppMenuButton extends StatelessWidget {
  const AppMenuButton({super.key, required this.commands});

  final Map<String, VoidCallback> commands;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      menuChildren: [
        for (final (title, entries) in _menus)
          SubmenuButton(
            key: Key('app-menu-${title.toLowerCase()}'),
            menuChildren: [
              for (final entry in entries)
                if (entry == null)
                  const Divider(height: 9)
                else
                  MenuItemButton(
                    key: Key('app-menu-${entry.$2}'),
                    onPressed: commands[entry.$2],
                    trailingIcon: entry.$3.isEmpty
                        ? null
                        : Text(
                            _keys(entry.$3),
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                    child: Text(entry.$1),
                  ),
            ],
            child: Text(title),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        key: const Key('app-menu'),
        tooltip: 'Menu',
        iconSize: 20,
        icon: const Icon(Icons.more_vert),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
