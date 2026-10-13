import 'package:flutter/material.dart';

import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/workspace/collection_actions.dart';
import 'package:reqorb/transfer/import_actions.dart';
import 'package:reqorb/transfer/export_actions.dart';
import 'package:reqorb/har/har_actions.dart';
import 'package:reqorb/settings/settings_dialog.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// The collections tree with import and export actions.
class Sidebar extends StatefulWidget {
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
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _filter = TextEditingController();

  WorkspaceStore get store => widget.store;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _remove(RequestRef ref) {
    final item = store.itemAt(ref);
    if (item == null) return;
    store.removeItem(ref);
    widget.onRemoved();
    showUndo(
      context,
      'Deleted "${item.name}"',
      () => store.insertItem(ref, item),
    );
  }

  Future<void> _rename(RequestRef ref) async {
    final item = store.itemAt(ref);
    if (item == null) return;
    final name = await askRequestName(context, item.name);
    // Only rename if the request is still where it was.
    if (name != null && identical(store.itemAt(ref), item)) {
      store.renameItem(ref, name);
    }
  }

  void _removeCollection(int index) {
    final collection = store.collections[index];
    store.removeCollection(index);
    widget.onRemoved();
    showUndo(
      context,
      'Deleted collection "${collection.name}"',
      () => store.insertCollection(index, collection),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final query = _filter.text.trim().toLowerCase();
    final hasRequests =
        store.requests.isNotEmpty ||
        store.collections.any((c) => c.items.isNotEmpty);
    // A Material, so tiles paint their highlights on the tinted background.
    return Material(
      color: scheme.surfaceContainerLow,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(child: Text('Collections', style: _heading(theme))),
                  if (widget.onCollapse != null)
                    IconButton(
                      key: const Key('hide-sidebar'),
                      tooltip: 'Hide sidebar (${shortcutModifier}B)',
                      iconSize: 20,
                      icon: const Icon(Icons.menu_open),
                      onPressed: widget.onCollapse,
                    ),
                  IconButton(
                    key: const Key('new-collection'),
                    tooltip: 'New collection',
                    iconSize: 20,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: () => newCollection(context, store),
                  ),
                  PopupMenuButton<VoidCallback>(
                    key: const Key('import-menu'),
                    tooltip: 'Import',
                    iconSize: 20,
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
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        key: const Key('analyze-har'),
                        value: () => analyzeHarFile(context, store),
                        child: const Text('Analyse HAR file…'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Only worth the space once there is something to search.
            if (hasRequests)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: TextField(
                  key: const Key('sidebar-filter'),
                  controller: _filter,
                  autocorrect: false,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: 'Filter requests',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    prefixIconConstraints: const BoxConstraints(minWidth: 36),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear filter',
                            iconSize: 16,
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(_filter.clear),
                          ),
                    filled: true,
                    fillColor: scheme.surface,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Expanded(
              child: query.isNotEmpty && hasRequests
                  ? _results(theme, query)
                  : _tree(theme),
            ),
            // Pinned below the list, so it stays put while the list scrolls.
            const Divider(height: 1),
            // Appears once something has been sent, since it is otherwise empty.
            if (store.session.isNotEmpty)
              ListTile(
                key: const Key('session'),
                dense: true,
                onTap: () => analyzeSession(context, store),
                leading: const Icon(Icons.history, size: 20),
                title: Text(
                  'Session · ${store.session.length} '
                  '${store.session.length == 1 ? 'request' : 'requests'}',
                ),
                trailing: PopupMenuButton<VoidCallback>(
                  key: const Key('session-menu'),
                  tooltip: 'Session actions',
                  iconSize: 18,
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      key: const Key('session-analyze'),
                      value: () => analyzeSession(context, store),
                      child: const Text('Analyse session'),
                    ),
                    PopupMenuItem(
                      key: const Key('session-export-har'),
                      value: () => exportSessionHar(context, store),
                      child: const Text('Export as HAR…'),
                    ),
                    PopupMenuItem(
                      key: const Key('session-clear'),
                      value: store.clearSession,
                      child: const Text('Clear session'),
                    ),
                  ],
                ),
              ),
            ListTile(
              key: const Key('settings'),
              dense: true,
              leading: const Icon(Icons.settings_outlined, size: 20),
              title: const Text('Settings'),
              onTap: () => SettingsDialog.show(context, store),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle? _heading(ThemeData theme) => theme.textTheme.labelLarge?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
  );

  Widget _tree(ThemeData theme) {
    return ListView(
      children: [
        if (store.collections.isEmpty)
          _hint(
            theme,
            'Import a swagger.json, a Postman collection, a HAR file or '
            'a curl command, or save a request into a new collection.',
          ),
        for (var i = 0; i < store.collections.length; i++) _collection(i),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            children: [
              Expanded(child: Text('Requests', style: _heading(theme))),
              IconButton(
                key: const Key('new-request'),
                tooltip: 'New request (${shortcutModifier}N)',
                iconSize: 20,
                icon: const Icon(Icons.add),
                onPressed: widget.onNewRequest,
              ),
            ],
          ),
        ),
        if (store.requests.isEmpty)
          _hint(theme, 'Requests saved without a collection appear here.'),
        for (var i = 0; i < store.requests.length; i++)
          if (store.requests[i].request case final request?)
            _tile(RequestRef.standalone(i), store.requests[i], request, 0),
      ],
    );
  }

  /// Every request matching [query], listed flat with where it lives.
  Widget _results(ThemeData theme, String query) {
    final found = <Widget>[];
    void walk(
      int collection,
      List<Item> items,
      List<int> parent,
      String where,
    ) {
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final path = [...parent, i];
        if (item.request case final request?) {
          final text = '${item.name} ${request.method} ${request.url}';
          if (text.toLowerCase().contains(query)) {
            found.add(
              _tile(RequestRef(collection, path), item, request, 0, where),
            );
          }
        }
        walk(
          collection,
          item.items,
          path,
          item.request == null ? '$where / ${item.name}' : where,
        );
      }
    }

    for (var c = 0; c < store.collections.length; c++) {
      walk(c, store.collections[c].items, const [], store.collections[c].name);
    }
    walk(RequestRef.noCollection, store.requests, const [], '');
    if (found.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: _hint(theme, 'No requests match "${_filter.text.trim()}".'),
      );
    }
    return ListView(children: found);
  }

  Widget _tile(
    RequestRef ref,
    Item item,
    Request request,
    double indent, [
    String where = '',
  ]) {
    return _RequestTile(
      name: item.name,
      where: where,
      method: request.method,
      indent: indent,
      selected: widget.selected == ref,
      onTap: () => widget.onOpen(ref),
      onRename: () => _rename(ref),
      onDuplicate: () => store.duplicateItem(ref),
      onDelete: () => _remove(ref),
    );
  }

  Widget _hint(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.4,
      ),
    ),
  );

  Widget _collection(int index) {
    final collection = store.collections[index];
    return ExpansionTile(
      // Keyed by identity so expansion state follows the collection.
      key: ObjectKey(collection),
      initiallyExpanded: true,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      shape: const Border(),
      tilePadding: const EdgeInsets.only(left: 8, right: 4),
      title: Text(
        collection.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      trailing: PopupMenuButton<VoidCallback>(
        tooltip: 'Collection actions',
        iconSize: 18,
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
            key: const Key('delete-collection'),
            value: () => _removeCollection(index),
            child: const Text('Delete collection'),
          ),
        ],
      ),
      children: collection.items.isEmpty
          ? [
              _hint(
                Theme.of(context),
                'Empty. Save a request and choose this collection.',
              ),
            ]
          : _items(index, collection.items, const [], 1),
    );
  }

  List<Widget> _items(
    int collection,
    List<Item> items,
    List<int> parent,
    int depth,
  ) {
    final indent = 16.0 * depth;
    return [
      for (var i = 0; i < items.length; i++)
        if (items[i].request case final request?)
          _tile(
            RequestRef(collection, [...parent, i]),
            items[i],
            request,
            indent,
          )
        else
          ExpansionTile(
            key: ObjectKey(items[i]),
            initiallyExpanded: true,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            shape: const Border(),
            tilePadding: EdgeInsets.only(left: indent - 8, right: 8),
            title: Text(
              items[i].name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            children: _items(collection, items[i].items, [
              ...parent,
              i,
            ], depth + 1),
          ),
    ];
  }
}

class _RequestTile extends StatefulWidget {
  const _RequestTile({
    required this.name,
    required this.where,
    required this.method,
    required this.indent,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDuplicate,
    required this.onDelete,
  });

  final String name;

  /// The collection and folders the request is in, shown in filter results.
  final String where;
  final String method;
  final double indent;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  State<_RequestTile> createState() => _RequestTileState();
}

class _RequestTileState extends State<_RequestTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // With a pointer the actions appear on hover, which keeps a long list
    // quiet; on touch there is no hover, so they are always shown.
    final showActions = !isDesktop || _hovered || widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          color: widget.selected
              ? scheme.secondaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: isDesktop ? 32 : 44),
              child: Padding(
                padding: EdgeInsets.only(left: widget.indent + 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 46,
                      child: Text(
                        widget.method.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: mono.copyWith(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: methodColor(widget.method, theme.brightness),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: widget.selected
                                  ? scheme.onSecondaryContainer
                                  : null,
                            ),
                          ),
                          if (widget.where.isNotEmpty)
                            Text(
                              widget.where,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Kept in the tree while hidden, so the row does not
                    // change width and the keyboard can still reach it.
                    Opacity(
                      opacity: showActions ? 1 : 0,
                      child: PopupMenuButton<VoidCallback>(
                        tooltip: 'Request actions',
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.more_horiz),
                        onSelected: (action) => action(),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            key: const Key('rename-request'),
                            value: widget.onRename,
                            child: const Text('Rename…'),
                          ),
                          PopupMenuItem(
                            key: const Key('duplicate-request'),
                            value: widget.onDuplicate,
                            child: const Text('Duplicate'),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            key: const Key('delete-request'),
                            value: widget.onDelete,
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
