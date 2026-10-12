import 'package:flutter/material.dart';

import 'actions.dart';
import 'settings_dialog.dart';
import 'src/rust/api/core.dart';
import 'workspace_store.dart';

/// The collections tree with import and export actions.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.store,
    required this.selected,
    required this.onOpen,
    required this.onNewRequest,
    required this.onRemoved,
    this.onCollapse,
  });

  final WorkspaceStore store;
  final RequestRef? selected;
  final ValueChanged<RequestRef> onOpen;

  /// Starts a blank request in the editor.
  final VoidCallback onNewRequest;

  /// Called after anything is deleted, since saved positions may have moved.
  final VoidCallback onRemoved;

  /// Hides the sidebar; null when it is shown as a drawer instead.
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text('Collections', style: theme.textTheme.titleSmall),
                ),
                if (onCollapse != null)
                  IconButton(
                    key: const Key('hide-sidebar'),
                    tooltip: 'Hide collections',
                    icon: const Icon(Icons.menu_open),
                    onPressed: onCollapse,
                  ),
                IconButton(
                  key: const Key('new-collection'),
                  tooltip: 'New collection',
                  icon: const Icon(Icons.add),
                  onPressed: () => newCollection(context, store),
                ),
                PopupMenuButton<VoidCallback>(
                  key: const Key('import-menu'),
                  tooltip: 'Import',
                  icon: const Icon(Icons.file_download_outlined),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: () => importFromFile(context, store),
                      child: const Text('Import file…'),
                    ),
                    PopupMenuItem(
                      key: const Key('import-url'),
                      value: () => importFromUrl(context, store),
                      child: const Text('Import from URL…'),
                    ),
                    PopupMenuItem(
                      key: const Key('import-paste'),
                      value: () => importFromPaste(context, store),
                      child: const Text('Paste curl or JSON…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (store.collections.isEmpty)
                  _hint(
                    theme,
                    'Import a swagger.json, a Postman collection or a curl '
                    'command, or save a request into a new collection.',
                  ),
                for (var i = 0; i < store.collections.length; i++)
                  _collection(context, i),
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Requests',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        key: const Key('new-request'),
                        tooltip: 'New request',
                        icon: const Icon(Icons.add),
                        onPressed: onNewRequest,
                      ),
                    ],
                  ),
                ),
                if (store.requests.isEmpty)
                  _hint(
                    theme,
                    'Requests saved without a collection appear here.',
                  ),
                for (var i = 0; i < store.requests.length; i++)
                  if (store.requests[i].request case final request?)
                    _RequestTile(
                      name: store.requests[i].name,
                      method: request.method,
                      indent: 0,
                      selected: selected == RequestRef.standalone(i),
                      onTap: () => onOpen(RequestRef.standalone(i)),
                      onDelete: () {
                        store.removeItem(RequestRef.standalone(i));
                        onRemoved();
                      },
                    ),
              ],
            ),
          ),
          // Pinned below the list, so it stays put while the list scrolls.
          const Divider(height: 1),
          ListTile(
            key: const Key('settings'),
            dense: true,
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => SettingsDialog.show(context, store),
          ),
        ],
      ),
    );
  }

  Widget _hint(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Text(
      text,
      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
    ),
  );

  Widget _collection(BuildContext context, int index) {
    final collection = store.collections[index];
    return ExpansionTile(
      // Keyed by identity so expansion state follows the collection.
      key: ObjectKey(collection),
      initiallyExpanded: true,
      controlAffinity: ListTileControlAffinity.leading,
      shape: const Border(),
      title: Text(
        collection.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      trailing: PopupMenuButton<VoidCallback>(
        tooltip: 'Collection actions',
        icon: const Icon(Icons.more_horiz),
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          PopupMenuItem(
            key: const Key('rename-collection'),
            value: () => renameCollection(context, store, index),
            child: const Text('Rename…'),
          ),
          const PopupMenuDivider(),
          for (final (label, format) in const [
            ('Export as curl…', ExportFormat.curl),
            ('Export as Bruno…', ExportFormat.bruno),
            ('Export as Postman…', ExportFormat.postman),
            ('Export as reqorb JSON…', ExportFormat.reqorb),
          ])
            PopupMenuItem(
              value: () => exportCollectionFile(context, collection, format),
              child: Text(label),
            ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: () {
              store.removeCollection(index);
              onRemoved();
            },
            child: const Text('Delete collection'),
          ),
        ],
      ),
      children: _items(context, index, collection.items, const [], 1),
    );
  }

  List<Widget> _items(
    BuildContext context,
    int collection,
    List<Item> items,
    List<int> parent,
    int depth,
  ) {
    final indent = 16.0 * depth;
    return [
      for (var i = 0; i < items.length; i++)
        if (items[i].request case final request?)
          _RequestTile(
            name: items[i].name,
            method: request.method,
            indent: indent,
            selected: selected == RequestRef(collection, [...parent, i]),
            onTap: () => onOpen(RequestRef(collection, [...parent, i])),
            onDelete: () {
              store.removeItem(RequestRef(collection, [...parent, i]));
              onRemoved();
            },
          )
        else
          ExpansionTile(
            key: ObjectKey(items[i]),
            initiallyExpanded: true,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            shape: const Border(),
            tilePadding: EdgeInsets.only(left: indent, right: 8),
            title: Text(
              items[i].name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            children: _items(context, collection, items[i].items, [
              ...parent,
              i,
            ], depth + 1),
          ),
    ];
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.name,
    required this.method,
    required this.indent,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final String name;
  final String method;
  final double indent;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: scheme.secondaryContainer,
      contentPadding: EdgeInsets.only(left: indent + 16, right: 4),
      leading: SizedBox(
        width: 48,
        child: Text(
          method.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: TextStyle(
            fontFamily: 'Menlo',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      ),
      horizontalTitleGap: 4,
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: 'Delete request',
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.close),
        onPressed: onDelete,
      ),
      onTap: onTap,
    );
  }
}
