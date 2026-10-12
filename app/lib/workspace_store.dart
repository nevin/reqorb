import 'dart:async';

import 'package:flutter/foundation.dart';

import 'src/rust/api/core.dart';

/// Where a saved request lives: a collection and the item indices leading to it.
@immutable
class RequestRef {
  const RequestRef(this.collection, this.path);

  /// A saved request that is not in any collection.
  RequestRef.standalone(int index) : this(noCollection, [index]);

  /// Value of [collection] for requests saved outside any collection.
  static const noCollection = -1;

  final int collection;
  final List<int> path;

  @override
  bool operator ==(Object other) =>
      other is RequestRef &&
      other.collection == collection &&
      listEquals(other.path, path);

  @override
  int get hashCode => Object.hash(collection, Object.hashAll(path));
}

/// Holds the workspace and writes it to disk shortly after every change.
class WorkspaceStore extends ChangeNotifier {
  WorkspaceStore(this.path);

  /// Location of `workspace.json`.
  final String path;

  Workspace _workspace = const Workspace(
    collections: [],
    requests: [],
    environments: [],
    settings: Settings(
      theme: AppTheme.system,
      httpMode: HttpMode.auto,
      timeoutSecs: 0,
    ),
    cookies: [],
  );
  Timer? _saveTimer;

  /// The last load or save failure, if any.
  String? error;

  List<Collection> get collections => _workspace.collections;

  /// Saved requests that are not in any collection.
  List<Item> get requests => _workspace.requests;
  List<Environment> get environments => _workspace.environments;
  String? get activeEnvironment => _workspace.activeEnvironment;
  Settings get settings => _workspace.settings;

  void updateSettings(Settings settings) => _set(settings: settings);

  // -------------------------------------------------------------- cookies

  /// The cookie jar shared by every request.
  List<Cookie> get cookies => _workspace.cookies;

  /// Replaces the jar, typically with what a request left behind.
  void setCookies(List<Cookie> cookies) {
    if (!listEquals(cookies, _workspace.cookies)) _set(cookies: cookies);
  }

  /// Adds a cookie, replacing one with the same name, domain and path.
  void putCookie(Cookie cookie) => _set(
    cookies: [
      for (final c in cookies)
        if (!(c.name == cookie.name &&
            c.domain == cookie.domain &&
            c.path == cookie.path))
          c,
      cookie,
    ],
  );

  void removeCookie(Cookie cookie) =>
      _set(cookies: [...cookies]..remove(cookie));

  void clearCookies() => _set(cookies: const []);

  Future<void> load() async {
    try {
      _workspace = await loadWorkspace(path: path);
      error = null;
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  /// Writes any pending change now.
  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _save();
    }
  }

  Future<void> _save() async {
    try {
      await saveWorkspace(path: path, workspace: _workspace);
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  void _set({
    List<Collection>? collections,
    List<Item>? requests,
    List<Environment>? environments,
    String? Function()? activeEnvironment,
    Settings? settings,
    List<Cookie>? cookies,
  }) {
    _workspace = Workspace(
      collections: collections ?? _workspace.collections,
      requests: requests ?? _workspace.requests,
      environments: environments ?? _workspace.environments,
      activeEnvironment: activeEnvironment != null
          ? activeEnvironment()
          : _workspace.activeEnvironment,
      settings: settings ?? _workspace.settings,
      cookies: cookies ?? _workspace.cookies,
    );
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _save);
  }

  // ------------------------------------------------------------ variables

  /// Variables for a request, highest priority first: the active
  /// environment, then the request's own collection.
  List<Variable> variablesFor(int? collection) {
    final name = activeEnvironment;
    return [
      for (final e in environments)
        if (e.name == name) ...e.variables,
      if (collection != null &&
          collection >= 0 &&
          collection < collections.length)
        ...collections[collection].variables,
    ];
  }

  // --------------------------------------------------------------- import

  /// Adds imported collections and environments to the workspace.
  void merge(ImportResult result) {
    final names = {for (final e in environments) e.name};
    final added = <Environment>[];
    for (final e in result.environments) {
      final name = _unique(e.name, names);
      names.add(name);
      added.add(Environment(name: name, variables: e.variables));
    }
    _set(
      collections: [...collections, ...result.collections],
      environments: [...environments, ...added],
    );
  }

  static String _unique(String wanted, Set<String> taken) {
    final base = wanted.trim().isEmpty ? 'Untitled' : wanted.trim();
    var name = base;
    for (var i = 2; taken.contains(name); i++) {
      name = '$base ($i)';
    }
    return name;
  }

  // ---------------------------------------------------------- collections

  Item? itemAt(RequestRef ref) {
    final standalone = ref.collection == RequestRef.noCollection;
    if (ref.path.isEmpty) return null;
    if (!standalone &&
        (ref.collection < 0 || ref.collection >= collections.length)) {
      return null;
    }
    var items = standalone ? requests : collections[ref.collection].items;
    Item? item;
    for (final i in ref.path) {
      if (i >= items.length) return null;
      item = items[i];
      items = item.items;
    }
    return item;
  }

  /// Adds an empty collection and returns its index.
  int addCollection(String name) {
    _set(
      collections: [
        ...collections,
        Collection(name: name, variables: const [], items: const []),
      ],
    );
    return collections.length - 1;
  }

  void renameCollection(int index, String name) {
    final all = [...collections];
    final target = all[index];
    all[index] = Collection(
      name: name,
      variables: target.variables,
      items: target.items,
    );
    _set(collections: all);
  }

  void removeCollection(int index) {
    _set(collections: [...collections]..removeAt(index));
  }

  /// Appends a request to a collection, creating the collection when
  /// [collection] is null.
  RequestRef addRequest({
    required int? collection,
    required String newCollectionName,
    required String name,
    required Request request,
  }) {
    final item = Item(name: name, request: request, items: const []);
    final all = [...collections];
    if (collection == null) {
      all.add(
        Collection(name: newCollectionName, variables: const [], items: [item]),
      );
      _set(collections: all);
      return RequestRef(all.length - 1, const [0]);
    }
    final target = all[collection];
    all[collection] = Collection(
      name: target.name,
      variables: target.variables,
      items: [...target.items, item],
    );
    _set(collections: all);
    return RequestRef(collection, [target.items.length]);
  }

  /// Saves a request on its own, outside any collection.
  RequestRef addStandaloneRequest(String name, Request request) {
    _set(
      requests: [
        ...requests,
        Item(name: name, request: request, items: const []),
      ],
    );
    return RequestRef.standalone(requests.length - 1);
  }

  void updateRequest(RequestRef ref, Request request) => _changeItem(
    ref,
    (item) => Item(name: item.name, request: request, items: item.items),
  );

  void removeItem(RequestRef ref) => _changeItem(ref, (_) => null);

  void _changeItem(RequestRef ref, Item? Function(Item) change) {
    if (itemAt(ref) == null) return;
    if (ref.collection == RequestRef.noCollection) {
      _set(requests: _replace(requests, ref.path, change));
      return;
    }
    final all = [...collections];
    final target = all[ref.collection];
    all[ref.collection] = Collection(
      name: target.name,
      variables: target.variables,
      items: _replace(target.items, ref.path, change),
    );
    _set(collections: all);
  }

  static List<Item> _replace(
    List<Item> items,
    List<int> path,
    Item? Function(Item) change,
  ) {
    final i = path.first;
    final out = [...items];
    if (path.length == 1) {
      final next = change(items[i]);
      if (next == null) {
        out.removeAt(i);
      } else {
        out[i] = next;
      }
    } else {
      out[i] = Item(
        name: items[i].name,
        request: items[i].request,
        items: _replace(items[i].items, path.sublist(1), change),
      );
    }
    return out;
  }

  // --------------------------------------------------------- environments

  void setActiveEnvironment(String? name) {
    _set(activeEnvironment: () => name);
  }

  /// Adds an empty environment and returns its index.
  int addEnvironment() {
    final name = _unique('New environment', {
      for (final e in environments) e.name,
    });
    _set(
      environments: [
        ...environments,
        Environment(name: name, variables: const []),
      ],
    );
    return environments.length - 1;
  }

  /// Whether [name] is free for the environment at [index] to use.
  bool canRename(int index, String name) {
    if (name.trim().isEmpty) return false;
    for (var i = 0; i < environments.length; i++) {
      if (i != index && environments[i].name == name.trim()) return false;
    }
    return true;
  }

  void updateEnvironment(int index, Environment environment) {
    final old = environments[index];
    final all = [...environments];
    all[index] = environment;
    _set(
      environments: all,
      // Keep the selection when the active environment is renamed.
      activeEnvironment: activeEnvironment == old.name
          ? () => environment.name
          : null,
    );
  }

  void removeEnvironment(int index) {
    final removed = environments[index];
    _set(
      environments: [...environments]..removeAt(index),
      activeEnvironment: activeEnvironment == removed.name ? () => null : null,
    );
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
