import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/files/file_page.dart';

import 'package:reqorb/runner/collection_run.dart';
import 'package:reqorb/runner/runner_dialog.dart';
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
    required this.onMove,
    required this.onHistory,
    required this.onSpecs,
    this.onCollapse,
  });

  final WorkspaceStore store;
  final RequestRef? selected;
  final ValueChanged<RequestRef> onOpen;

  /// Starts a blank request in the editor.
  final VoidCallback onNewRequest;

  /// Called after anything is deleted or put back, since saved positions
  /// may have moved.
  final VoidCallback onRemoved;

  /// Moves a saved request to another place: before the item there, or
  /// to the end of the collection or folder when the place is past it.
  final void Function(RequestRef from, RequestRef to) onMove;

  /// Shows the requests sent before.
  final VoidCallback onHistory;

  /// Opens the page for reading and editing API specs.
  final VoidCallback onSpecs;

  /// Hides the sidebar; null when it is shown as a drawer instead.
  final VoidCallback? onCollapse;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _filter = TextEditingController();
  final _treeScroll = ScrollController();
  final _resultsScroll = ScrollController();

  WorkspaceStore get store => widget.store;

  @override
  void dispose() {
    _filter.dispose();
    _treeScroll.dispose();
    _resultsScroll.dispose();
    super.dispose();
  }

  void _remove(RequestRef ref) {
    final item = store.itemAt(ref);
    if (item == null) return;
    store.removeItem(ref);
    widget.onRemoved();
    showUndo(context, 'Deleted "${item.name}"', () {
      store.insertItem(ref, item);
      widget.onRemoved();
    });
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
    showUndo(context, 'Deleted collection "${collection.name}"', () {
      store.insertCollection(index, collection);
      widget.onRemoved();
    });
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
                      PopupMenuItem(
                        key: const Key('open-folder'),
                        value: () => openCollectionFolder(context, store),
                        child: const Text('Open collection folder…'),
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
                leading: const Icon(Icons.timeline, size: 20),
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
                      value: () => showUndo(
                        context,
                        'Cleared the session',
                        store.clearSession(),
                      ),
                      child: const Text('Clear session'),
                    ),
                  ],
                ),
              ),
            // The places of the app, side by side so that the list above
            // keeps the height.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  _Place(
                    key: const Key('history'),
                    icon: Icons.history,
                    label: 'History',
                    tooltip: store.history.isEmpty
                        ? 'Requests sent before'
                        : 'History · ${store.history.length}',
                    count: store.history.length,
                    onTap: widget.onHistory,
                  ),
                  _Place(
                    key: const Key('api-specs'),
                    icon: Icons.description_outlined,
                    label: 'Specs',
                    tooltip: 'API specs: OpenAPI and Swagger',
                    onTap: widget.onSpecs,
                  ),
                  _Place(
                    key: const Key('open-file'),
                    icon: Icons.file_open_outlined,
                    label: 'File',
                    tooltip: 'Open file… (${shortcutModifier}O)',
                    onTap: () => openFile(context),
                  ),
                  _Place(
                    key: const Key('har-analyser'),
                    icon: Icons.insights,
                    label: 'HAR',
                    tooltip: 'HAR analyser',
                    onTap: () => analyzeHarFile(context, store),
                  ),
                  _Place(
                    key: const Key('settings'),
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    tooltip: 'Settings',
                    onTap: () => SettingsDialog.show(context, store),
                  ),
                ],
              ),
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

  /// A list with its scrollbar always on show, so that it is plain when
  /// there is more below than fits.
  Widget _scrolling(ScrollController controller, List<Widget> children) =>
      Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: ListView(
          controller: controller,
          // Room for the bar, clear of the buttons at the end of each row.
          padding: const EdgeInsets.only(right: 6),
          children: children,
        ),
      );

  Widget _tree(ThemeData theme) {
    return _scrolling(_treeScroll, [
      if (store.collections.isEmpty) ...[
        _hint(
          theme,
          'Nothing is saved yet. Bring requests in, or start a '
          'collection to save your own into.',
        ),
        for (final (key, icon, label, action) in [
          (
            'start-import',
            Icons.file_download_outlined,
            'Import a file…',
            () => importFromFile(context, store),
          ),
          (
            'start-paste',
            Icons.content_paste,
            'Paste curl or JSON…',
            () => importFromPaste(context, store),
          ),
          (
            'start-folder',
            Icons.folder_open_outlined,
            'Open a collection folder…',
            () => openCollectionFolder(context, store),
          ),
          (
            'start-collection',
            Icons.create_new_folder_outlined,
            'New collection',
            () => newCollection(context, store),
          ),
        ])
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: TextButton.icon(
                key: Key(key),
                onPressed: action,
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
            ),
          ),
        _hint(
          theme,
          'Postman, OpenAPI or Swagger, HAR and .env files '
          'can all be imported.',
        ),
      ],
      for (var i = 0; i < store.collections.length; i++) _collection(i),
      const Divider(height: 24),
      _dropInto(
        const RequestRef(RequestRef.noCollection, [_atEnd]),
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            children: [
              Expanded(child: Text('Requests', style: _heading(theme))),
              if (store.requests.length > 1)
                IconButton(
                  key: const Key('run-requests'),
                  tooltip: 'Run these requests',
                  iconSize: 20,
                  icon: const Icon(Icons.play_arrow_outlined),
                  onPressed: () => showRunner(
                    context,
                    store: store,
                    name: 'requests',
                    steps: runSteps(store.requests, null),
                  ),
                ),
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
      ),
      if (store.requests.isEmpty)
        _hint(theme, 'Requests saved without a collection appear here.'),
      for (var i = 0; i < store.requests.length; i++)
        if (store.requests[i].request case final request?)
          _tile(RequestRef.standalone(i), store.requests[i], request, 0),
    ]);
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
    return _scrolling(_resultsScroll, found);
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
      // Only where the tree is shown as it is kept can it be rearranged.
      place: where.isEmpty ? ref : null,
      onDropped: (from) => widget.onMove(from, ref),
      onMoveTo: () => _moveTo(ref),
      onTap: () => widget.onOpen(ref),
      onRename: () => _rename(ref),
      onCopyAddress: () {
        Clipboard.setData(ClipboardData(text: request.url));
        showMessage(context, 'Copied the address');
      },
      onDuplicate: () => store.duplicateItem(ref),
      onDelete: () => _remove(ref),
    );
  }

  /// Makes [child] somewhere a dragged request can be dropped, to go to
  /// [to]; it is tinted while one is held over it.
  Widget _dropInto(RequestRef to, {required Widget child}) =>
      DragTarget<RequestRef>(
        onAcceptWithDetails: (details) => widget.onMove(details.data, to),
        builder: (context, held, _) => DecoratedBox(
          decoration: BoxDecoration(
            color: held.isEmpty
                ? null
                : Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: child,
        ),
      );

  /// Asks which collection or folder a request should go to, and moves
  /// it to the end of the one chosen.
  Future<void> _moveTo(RequestRef ref) async {
    final item = store.itemAt(ref);
    if (item == null) return;
    final places = <(String, RequestRef)>[];
    void folders(
      int collection,
      List<Item> items,
      List<int> parent,
      String where,
    ) {
      for (final (i, child) in items.indexed) {
        if (child.request != null) continue;
        final path = [...parent, i];
        final name = '$where / ${child.name}';
        places.add((name, RequestRef(collection, [...path, _atEnd])));
        folders(collection, child.items, path, name);
      }
    }

    for (final (i, collection) in store.collections.indexed) {
      places.add((collection.name, RequestRef(i, const [_atEnd])));
      folders(i, collection.items, const [], collection.name);
    }
    places.add((
      'Requests, outside any collection',
      const RequestRef(RequestRef.noCollection, [_atEnd]),
    ));
    final to = await showDialog<RequestRef>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('move-to'),
        title: Text('Move "${item.name}" to'),
        children: [
          for (final (name, place) in places)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, place),
              child: Text(name),
            ),
        ],
      ),
    );
    // Only if the request is still where it was.
    if (to != null && identical(store.itemAt(ref), item)) {
      widget.onMove(ref, to);
    }
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
      title: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (details) =>
            _menuAt(context, details.globalPosition, _collectionActions(index)),
        child: _dropInto(
          RequestRef(index, const [_atEnd]),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  collection.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (collection.link case final link?) ...[
                const SizedBox(width: 6),
                _FolderMark(
                  path: link.path,
                  problem: store.folderProblems[link.path],
                ),
              ],
            ],
          ),
        ),
      ),
      trailing: PopupMenuButton<VoidCallback>(
        tooltip: 'Collection actions',
        iconSize: 18,
        icon: const Icon(Icons.more_horiz),
        onSelected: (action) => action(),
        itemBuilder: (_) => _collectionActions(index),
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

  /// What can be done with a collection, for the button at the end of its
  /// row and for a right click on its name.
  List<PopupMenuEntry<VoidCallback>> _collectionActions(int index) {
    final collection = store.collections[index];
    return [
      PopupMenuItem(
        key: const Key('run-collection'),
        value: () => showRunner(
          context,
          store: store,
          name: collection.name,
          steps: runSteps(collection.items, index),
        ),
        child: const Text('Run…'),
      ),
      PopupMenuItem(
        key: const Key('rename-collection'),
        value: () => renameCollection(context, store, index),
        child: const Text('Rename…'),
      ),
      const PopupMenuDivider(),
      if (collection.link == null)
        PopupMenuItem(
          key: const Key('link-collection'),
          value: () => keepInFolder(context, store, index),
          child: const Text('Keep in a folder…'),
        )
      else ...[
        PopupMenuItem(
          key: const Key('reload-collection'),
          value: () => reloadFromFolder(context, store, index),
          child: const Text('Reload from folder'),
        ),
        if (store.folderConflicts.contains(collection.link?.path))
          PopupMenuItem(
            key: const Key('keep-mine'),
            value: () => keepMineInFolder(context, store, index),
            child: const Text('Keep mine, over the folder'),
          ),
        PopupMenuItem(
          key: const Key('unlink-collection'),
          value: () => store.unlinkCollection(index),
          child: const Text('Stop keeping in folder'),
        ),
      ],
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
    ];
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
            title: _dropInto(
              RequestRef(collection, [...parent, i, _atEnd]),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  items[i].name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            trailing: IconButton(
              key: Key('run-folder-${[...parent, i].join('-')}'),
              tooltip: 'Run this folder',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.play_arrow_outlined),
              onPressed: () => showRunner(
                context,
                store: store,
                name: items[i].name,
                steps: runSteps(items[i].items, collection),
              ),
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
    required this.place,
    required this.onDropped,
    required this.onMoveTo,
    required this.onTap,
    required this.onRename,
    required this.onCopyAddress,
    required this.onDuplicate,
    required this.onDelete,
  });

  final String name;

  /// The collection and folders the request is in, shown in filter results.
  final String where;
  final String method;
  final double indent;
  final bool selected;

  /// Where the request is kept, when its row can be dragged elsewhere
  /// and have others dropped on it.
  final RequestRef? place;

  /// Called with a request dropped on this one, to go before it.
  final ValueChanged<RequestRef> onDropped;

  /// Asks where to move the request.
  final VoidCallback onMoveTo;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onCopyAddress;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  State<_RequestTile> createState() => _RequestTileState();
}

class _RequestTileState extends State<_RequestTile> {
  bool _hovered = false;

  /// What can be done with the request, for the button at the end of its
  /// row and for a right click anywhere on it.
  List<PopupMenuEntry<VoidCallback>> _actions() => [
    PopupMenuItem(
      key: const Key('open-request'),
      value: widget.onTap,
      child: const Text('Open'),
    ),
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
    if (widget.place != null)
      PopupMenuItem(
        key: const Key('move-request'),
        value: widget.onMoveTo,
        child: const Text('Move to…'),
      ),
    PopupMenuItem(
      key: const Key('copy-request-address'),
      value: widget.onCopyAddress,
      child: const Text('Copy address'),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(
      key: const Key('delete-request'),
      value: widget.onDelete,
      child: const Text('Delete'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // With a pointer the actions appear on hover, which keeps a long list
    // quiet; on touch there is no hover, so they are always shown.
    final showActions = !isDesktop || _hovered || widget.selected;
    final place = widget.place;
    if (place == null) return _row(theme, showActions);
    // What follows the pointer while the request is dragged.
    final held = Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          '${widget.method.toUpperCase()}  ${widget.name}',
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
    final row = _row(theme, showActions);
    return DragTarget<RequestRef>(
      onWillAcceptWithDetails: (details) => details.data != place,
      onAcceptWithDetails: (details) => widget.onDropped(details.data),
      // A line above the row shows where the one held would go.
      builder: (context, over, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              width: 2,
              color: over.isEmpty ? Colors.transparent : scheme.primary,
            ),
          ),
        ),
        // A pointer drags at once; a finger holds first, so that the
        // list can still be scrolled.
        child: isDesktop
            ? Draggable<RequestRef>(
                data: place,
                feedback: held,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                child: row,
              )
            : LongPressDraggable<RequestRef>(
                data: place,
                feedback: held,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                child: row,
              ),
      ),
    );
  }

  Widget _row(ThemeData theme, bool showActions) {
    final scheme = theme.colorScheme;
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
            onSecondaryTapUp: (details) =>
                _menuAt(context, details.globalPosition, _actions()),
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
                        itemBuilder: (_) => _actions(),
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

/// Marks a collection that is kept in a folder, and says so when the
/// folder could not be read or written.
class _FolderMark extends StatelessWidget {
  const _FolderMark({required this.path, required this.problem});

  final String path;
  final String? problem;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final problem = this.problem;
    return Tooltip(
      message: problem == null
          ? 'Kept in $path'
          : 'The folder $path is out of step: $problem',
      child: Icon(
        problem == null ? Icons.folder_outlined : Icons.sync_problem,
        key: Key(problem == null ? 'folder-mark' : 'folder-problem'),
        size: 15,
        color: problem == null ? scheme.onSurfaceVariant : scheme.error,
      ),
    );
  }
}

/// A place past the last in any list, for moving something to its end.
const _atEnd = 1 << 30;

/// Shows [items] as a menu at a place in the window, and does what is
/// chosen from it.
void _menuAt(
  BuildContext context,
  Offset at,
  List<PopupMenuEntry<VoidCallback>> items,
) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
    items: items,
  ).then((action) => action?.call());
}

/// One of the places of the app at the foot of the sidebar: an icon with
/// its name beneath, and how many things it holds when that is worth
/// saying.
class _Place extends StatelessWidget {
  const _Place({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.count = 0,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Expanded(
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: isDesktop ? 6 : 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Badge(
                  isLabelVisible: count > 0,
                  // Clear of the icon, which it would otherwise cover.
                  offset: const Offset(12, -4),
                  label: Text(count > 99 ? '99+' : '$count'),
                  backgroundColor: scheme.secondaryContainer,
                  textColor: scheme.onSecondaryContainer,
                  child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
