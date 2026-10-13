import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/src/rust/api/core.dart';

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
  WorkspaceStore(this.path, {this.engine = const RustEngine()});

  /// Reads and writes the workspace file.
  final Engine engine;

  /// Location of `workspace.json`.
  final String path;

  late Workspace _workspace = Workspace(
    collections: const [],
    requests: const [],
    environments: const [],
    settings: engine.defaultSettings(),
    cookies: const [],
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

  // -------------------------------------------------------------- session

  /// Every HTTP exchange made since the app started, oldest first. Kept in
  /// memory only, so that it can be exported as a HAR file.
  List<Exchange> get session => _session;
  List<Exchange> _session = const [];

  void addExchanges(List<Exchange> exchanges) {
    if (exchanges.isEmpty) return;
    _session = [..._session, ...exchanges];
    notifyListeners();
  }

  void clearSession() {
    _session = const [];
    _captured = const [];
    notifyListeners();
  }

  /// Variables captured from responses this session, newest first. They take
  /// priority over the environment's and the collection's.
  List<Variable> get captured => _captured;
  List<Variable> _captured = const [];

  void capture(List<Variable> variables) {
    if (variables.isEmpty) return;
    final names = {for (final v in variables) v.key};
    _captured = [
      ...variables.reversed,
      for (final v in _captured)
        if (!names.contains(v.key)) v,
    ];
    notifyListeners();
  }

  Future<void> load() async {
    try {
      _workspace = await engine.loadWorkspace(path: path);
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
      await engine.saveWorkspace(path: path, workspace: _workspace);
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

  /// Variables for a request, highest priority first: what this session
  /// captured, the active environment, then the request's own collection.
  List<Variable> variablesFor(int? collection) {
    final name = activeEnvironment;
    return [
      ..._captured,
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

  /// Puts a removed collection back where it was.
  void insertCollection(int index, Collection collection) {
    _set(
      collections: [...collections]
        ..insert(index.clamp(0, collections.length), collection),
    );
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

  void renameItem(RequestRef ref, String name) => _changeItem(
    ref,
    (item) => Item(name: name, request: item.request, items: item.items),
  );

  /// Adds [item] as a sibling at [ref], which is how a removal is undone.
  void insertItem(RequestRef ref, Item item) {
    if (ref.path.isEmpty) return;
    if (ref.collection == RequestRef.noCollection) {
      _set(requests: _insert(requests, ref.path, item));
      return;
    }
    if (ref.collection < 0 || ref.collection >= collections.length) return;
    final all = [...collections];
    final target = all[ref.collection];
    all[ref.collection] = Collection(
      name: target.name,
      variables: target.variables,
      items: _insert(target.items, ref.path, item),
    );
    _set(collections: all);
  }

  /// Copies a request to the end of the folder it is in, so that no other
  /// request changes position.
  void duplicateItem(RequestRef ref) {
    final item = itemAt(ref);
    if (item == null) return;
    final parent = ref.path.sublist(0, ref.path.length - 1);
    insertItem(
      RequestRef(ref.collection, [...parent, 1 << 30]),
      Item(name: '${item.name} copy', request: item.request, items: item.items),
    );
  }

  static List<Item> _insert(List<Item> items, List<int> path, Item item) {
    final i = path.first;
    final out = [...items];
    if (path.length == 1) {
      out.insert(i.clamp(0, out.length), item);
    } else if (i < items.length) {
      out[i] = Item(
        name: items[i].name,
        request: items[i].request,
        items: _insert(items[i].items, path.sublist(1), item),
      );
    }
    return out;
  }

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

  /// Puts a removed environment back, selecting it again if it was in use.
  void insertEnvironment(
    int index,
    Environment environment, {
    required bool active,
  }) {
    _set(
      environments: [...environments]
        ..insert(index.clamp(0, environments.length), environment),
      activeEnvironment: active ? () => environment.name : null,
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

/// Copies of the app settings with some of them changed.
extension SettingsCopy on Settings {
  Settings copyWith({
    AppTheme? theme,
    HttpMode? httpMode,
    int? timeoutSecs,
    int? maxResponseMb,
    bool? verifySsl,
    bool? followRedirects,
    bool? sendNoCache,
    bool? confirmDiscard,
    Layout? layout,
    int? fontSize,
    Indent? indent,
    ProxyMode? proxy,
    String? proxyUrl,
  }) => Settings(
    theme: theme ?? this.theme,
    httpMode: httpMode ?? this.httpMode,
    timeoutSecs: timeoutSecs ?? this.timeoutSecs,
    maxResponseMb: maxResponseMb ?? this.maxResponseMb,
    verifySsl: verifySsl ?? this.verifySsl,
    followRedirects: followRedirects ?? this.followRedirects,
    sendNoCache: sendNoCache ?? this.sendNoCache,
    confirmDiscard: confirmDiscard ?? this.confirmDiscard,
    layout: layout ?? this.layout,
    fontSize: fontSize ?? this.fontSize,
    indent: indent ?? this.indent,
    proxy: proxy ?? this.proxy,
    proxyUrl: proxyUrl ?? this.proxyUrl,
  );
}
