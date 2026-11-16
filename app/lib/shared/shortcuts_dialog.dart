/// The keyboard shortcuts, listed in one place.
library;

import 'package:material_ui/material_ui.dart';
import 'package:reqorb/shared/theme.dart';

/// Each group of shortcuts: what the keys are and what they do. `⌘` stands
/// for Control where there is no Command key.
const _groups = <(String, List<(String, String)>)>[
  (
    'Requests',
    [
      ('⌘↵', 'Send, connect or call'),
      ('⌘.', 'Stop a send or a call'),
      ('⌘S', 'Save the request'),
      ('⌘L', 'Go to the address'),
      ('⌘N', 'New request'),
    ],
  ),
  (
    'Tabs',
    [
      ('⌘W', 'Close the tab'),
      ('⇧⌘T', 'Reopen the tab closed last'),
      ('⌘1 – ⌘8', 'Go to a tab by its place'),
      ('⌘9', 'Go to the last tab'),
      ('⌃Tab  ⇧⌘]', 'Next tab'),
      ('⌃⇧Tab  ⇧⌘[', 'Previous tab'),
    ],
  ),
  (
    'Finding your way',
    [
      ('⌘K  ⌘P', 'Find a request, tab, environment or action'),
      ('⌘B', 'Show or hide the sidebar'),
      ('⌘O', 'Open a file'),
      ('⌘/', 'These shortcuts'),
      ('⌘Z', 'Undo the last deletion, outside a text field'),
    ],
  ),
  (
    'Text and code',
    [
      ('⌘F', 'Find'),
      ('⌘G  ⇧⌘G', 'Next and previous match, in large text'),
      ('⌘⌥F', 'Find and replace'),
      ('Tab  ⇧Tab', 'Indent and outdent'),
      ('⌘+  ⌘-  ⌘0', 'Larger, smaller and usual size'),
    ],
  ),
];

/// The keys as they are on this platform.
String _keys(String keys) => shortcutModifier == '⌘'
    ? keys
    : keys
          .replaceAll('⇧⌘', 'Ctrl+Shift+')
          .replaceAll('⌘⌥', 'Ctrl+Alt+')
          .replaceAll('⌘', 'Ctrl+')
          .replaceAll('⌃⇧', 'Ctrl+Shift+')
          .replaceAll('⌃', 'Ctrl+')
          .replaceAll('⇧', 'Shift+')
          .replaceAll('↵', 'Enter');

/// Shows every keyboard shortcut.
Future<void> showShortcuts(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      key: const Key('shortcuts'),
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (title, shortcuts) in _groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 6),
                  child: Text(
                    title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final (keys, what) in shortcuts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 150,
                          child: Text(
                            _keys(keys),
                            style: mono.copyWith(
                              fontSize: 12,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        Expanded(child: Text(what)),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  },
);
