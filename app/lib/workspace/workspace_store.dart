import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/shared/folders.dart';
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

  /// How many saved credentials are still encrypted, because the key they
  /// were encrypted with could not be read, and why it could not.
  int lockedSecrets = 0;
  String? keyProblem;

  /// Why the last save left credentials unencrypted although the settings
  /// ask for them to be; null when they were encrypted, or need not be.
  String? unprotected;

  List<Collection> get collections => _workspace.collections;

  /// Saved requests that are not in any collection.
  List<Item> get requests => _workspace.requests;
  List<Environment> get environments => _workspace.environments;
  String? get activeEnvironment => _workspace.activeEnvironment;
  Settings get settings => _workspace.settings;

  void updateSettings(Settings settings) {
    final limit = settings.historyLimit;
    _set(settings: settings);
    // A smaller history takes effect at once, not at the next send.
    if (limit == 0 && (_history.isNotEmpty || unreadableHistory > 0)) {
      clearHistory();
    } else if (_history.length > limit) {
      _history = _history.sublist(_history.length - limit);
      notifyListeners();
    }
  }

  /// Takes up the permission to use the working directory again, as a
  /// sandboxed app must after every start. Follows the folder if it moved.
  Future<void> restoreWorkingDir(Folders folders) async {
    final grant = settings.workingDirGrant;
    if (grant.isEmpty) return;
    final path = await folders.restore(grant);
    if (path != null && path != settings.workingDir) {
      updateSettings(settings.copyWith(workingDir: path));
    }
  }

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
      final loaded = await engine.loadWorkspace(path: path);
      _workspace = loaded.workspace;
      lockedSecrets = loaded.locked;
      keyProblem = loaded.problem;
      error = null;
    } catch (e) {
      // What is in memory is now an empty workspace, and the first change
      // would save it over the file. Kept aside, its contents are not lost.
      final kept = await engine.keepAside(path: path);
      error = kept == null
          ? '$e'
          : 'The workspace could not be read: $e\n'
                'It was kept as $kept, and a new one was started.';
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
      final saving = _workspace;
      final why = await engine.saveWorkspace(path: path, workspace: saving);
      await _writeLinked(saving);
      // Entering a locked credential again replaces it, so the count of
      // those still locked can only be known by looking.
      final locked = lockedSecrets == 0
          ? 0
          : engine.lockedSecrets(workspace: saving);
      if (why != unprotected || locked != lockedSecrets) {
        unprotected = why;
        lockedSecrets = locked;
        notifyListeners();
      }
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

  // -------------------------------------------------------------- history

  /// Where the history is kept: beside the workspace file.
  String get historyPath {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return '${path.substring(0, slash + 1)}history.jsonl';
  }

  /// Every request sent and what came back, oldest first, kept from one
  /// launch to the next up to the limit in the settings.
  List<HistoryEntry> get history => _history;
  List<HistoryEntry> _history = const [];

  /// Entries in the history file that could not be read, for want of the
  /// key they were encrypted with.
  int unreadableHistory = 0;

  /// Writes to the history file one after another, in the order asked.
  Future<void> _historyWrites = Future.value();

  Future<void> loadHistory() async {
    try {
      final loaded = await engine.loadHistory(path: historyPath);
      _history = loaded.entries;
      unreadableHistory = loaded.unreadable;
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  /// Records what a send did: [exchanges] in the order they happened, the
  /// last of them being the answer to [source], the request as written.
  void record(
    List<Exchange> exchanges, {
    required Request source,
    String name = '',
  }) {
    addExchanges(exchanges);
    final limit = settings.historyLimit;
    if (exchanges.isEmpty || limit == 0) return;
    final entries = [
      for (final (i, exchange) in exchanges.indexed)
        HistoryEntry(
          exchange: exchange,
          source: i == exchanges.length - 1 ? source : null,
          name: i == exchanges.length - 1 ? name : '',
          cut: false,
        ),
    ];
    final all = [..._history, ...entries];
    _history = all.length > limit ? all.sublist(all.length - limit) : all;
    notifyListeners();
    final protect = settings.protectSecrets;
    _historyWrites = _historyWrites.then((_) async {
      try {
        await engine.appendHistory(
          path: historyPath,
          entries: entries,
          limit: limit,
          protect: protect,
        );
      } catch (e) {
        error = e.toString();
        notifyListeners();
      }
    });
  }

  void clearHistory() {
    _history = const [];
    unreadableHistory = 0;
    notifyListeners();
    _historyWrites = _historyWrites.then((_) async {
      try {
        await engine.clearHistory(path: historyPath);
      } catch (e) {
        error = e.toString();
        notifyListeners();
      }
    });
  }

  /// Completes when everything recorded so far is on disk.
  Future<void> historyWritten() => _historyWrites;

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
        Collection(
          name: name,
          variables: const [],
          items: const [],
          unreviewed: false,
        ),
      ],
    );
    return collections.length - 1;
  }

  /// Lets the scripts of the collection at [index] run from now on.
  void markReviewed(int index) {
    final target = collections[index];
    if (!target.unreviewed) return;
    _set(
      collections: [...collections]
        ..[index] = Collection(
          name: target.name,
          variables: target.variables,
          items: target.items,
          link: target.link,
          unreviewed: false,
        ),
    );
  }

  void renameCollection(int index, String name) {
    final all = [...collections];
    final target = all[index];
    all[index] = Collection(
      name: name,
      variables: target.variables,
      link: target.link,
      unreviewed: target.unreviewed,
      items: target.items,
    );
    _set(collections: all);
  }

  // -------------------------------------------------------------- folders

  /// What went wrong the last time a collection's folder was read or
  /// written, by the folder's path. Empty when all is well.
  final folderProblems = <String, String>{};

  /// Each linked collection as it was last written to its folder, so that
  /// only one that has changed is written again.
  final _written = <String, Collection>{};

  /// The environments kept in each linked folder, as last written there or
  /// read from it.
  final _writtenEnvironments = <String, List<Environment>>{};

  /// The environments kept in the folder at [dir].
  List<Environment> keptIn(String dir, [List<Environment>? from]) => [
    for (final e in from ?? environments)
      if (e.folder == dir) e,
  ];

  static bool _sameEnvironments(List<Environment>? a, List<Environment> b) =>
      a != null &&
      a.length == b.length &&
      [
        for (var i = 0; i < a.length; i++)
          a[i].name == b[i].name &&
              a[i].folder == b[i].folder &&
              listEquals(a[i].variables, b[i].variables),
      ].every((same) => same);

  /// Takes up the environments read from the folder at [dir]: each replaces
  /// the one of its name here, new ones are added, and those that were kept
  /// there but are gone from it, as after a pull, are removed.
  void _takeEnvironments(String dir, List<Environment> read) {
    final names = {for (final e in read) e.name};
    final byName = {for (final e in read) e.name: e};
    final out = <Environment>[];
    for (final e in environments) {
      if (byName.remove(e.name) case final replaced?) {
        out.add(replaced);
      } else if (e.folder != dir || names.contains(e.name)) {
        out.add(e);
      }
    }
    out.addAll(byName.values);
    _writtenEnvironments[dir] = read;
    if (!_sameEnvironments(environments, out)) {
      final active = activeEnvironment;
      _set(
        environments: out,
        activeEnvironment: active != null && !out.any((e) => e.name == active)
            ? () => null
            : null,
      );
    }
  }

  /// Keeps the environment at [index] in the folder of the collection at
  /// [collection], beside its requests; with null, no longer in any.
  void keepEnvironmentWith(int index, int? collection) {
    final environment = environments[index];
    final folder = collection == null
        ? null
        : collections[collection].link?.path;
    if (folder == environment.folder) return;
    updateEnvironment(
      index,
      Environment(
        name: environment.name,
        variables: environment.variables,
        folder: folder,
      ),
    );
  }

  /// Each linked folder's fingerprint when it was last read or written, to
  /// tell when its files have changed since, as by a pull.
  final _stamps = <String, String>{};

  /// Folders whose files changed on disk while the copy here changed too.
  /// Neither is written over the other until the user says which to keep.
  final folderConflicts = <String>{};

  static const _conflict =
      'The files changed on disk since reqorb last read them, and the copy '
      'here changed too. Reload from folder to take the files, or Keep mine '
      'to write this copy over them.';

  Future<void> _stamp(String dir) async {
    try {
      _stamps[dir] = await engine.collectionDirStamp(dir: dir);
    } catch (_) {
      _stamps.remove(dir);
    }
  }

  /// Whether the files in [dir] are not what they were when last read or
  /// written here.
  Future<bool> _changedOnDisk(String dir) async {
    final known = _stamps[dir];
    if (known == null) return false;
    try {
      return await engine.collectionDirStamp(dir: dir) != known;
    } catch (_) {
      return false;
    }
  }

  Collection _linked(Collection collection, FolderLink? link) => Collection(
    name: collection.name,
    variables: collection.variables,
    items: collection.items,
    link: link,
    unreviewed: collection.unreviewed,
  );

  /// Keeps the collection at [index] in the folder at [dir] from now on,
  /// one file for each request, and writes it there. Returns what went
  /// wrong, or null.
  Future<String?> linkCollection(int index, String dir, String grant) async {
    if (index < 0 || index >= collections.length) return null;
    if (engine.isCollectionDir(dir: dir)) {
      return 'That folder already holds a collection. Choose an empty '
          'folder, or use Open collection folder to work on the one there.';
    }
    final linked = _linked(
      collections[index],
      FolderLink(path: dir, grant: grant),
    );
    try {
      await engine.writeCollectionDir(dir: dir, collection: linked);
    } catch (e) {
      return '$e';
    }
    _written[dir] = linked;
    _writtenEnvironments[dir] = const [];
    await _stamp(dir);
    folderProblems.remove(dir);
    _set(collections: [...collections]..[index] = linked);
    return null;
  }

  /// Stops keeping the collection at [index] in its folder. The files stay
  /// where they are.
  void unlinkCollection(int index) {
    if (index < 0 || index >= collections.length) return;
    final dir = collections[index].link?.path;
    if (dir == null) return;
    _written.remove(dir);
    _writtenEnvironments.remove(dir);
    _stamps.remove(dir);
    folderConflicts.remove(dir);
    folderProblems.remove(dir);
    _set(
      collections: [...collections]
        ..[index] = _linked(collections[index], null),
      // Its environments stay, kept in the workspace from now on.
      environments: [
        for (final e in environments)
          e.folder == dir
              ? Environment(name: e.name, variables: e.variables)
              : e,
      ],
    );
  }

  /// Reads the collection at [index] again from its folder, as after the
  /// files were changed by a pull or by hand. Credentials, which the files
  /// do not hold, are kept from the copy here. Returns what went wrong.
  Future<String?> reloadCollection(int index) async {
    if (index < 0 || index >= collections.length) return null;
    final local = collections[index];
    final link = local.link;
    if (link == null) return null;
    try {
      final read = await engine.readCollectionDir(dir: link.path, local: local);
      final kept = await engine.readEnvironmentsDir(
        dir: link.path,
        local: environments,
      );
      await _stamp(link.path);
      folderProblems.remove(link.path);
      folderConflicts.remove(link.path);
      final at = collections.indexOf(local);
      if (at < 0) return null;
      // As read, it is also what the folder holds.
      _written[link.path] = read;
      _takeEnvironments(link.path, kept);
      if (read != local) {
        _set(collections: [...collections]..[at] = read);
      } else {
        notifyListeners();
      }
      return null;
    } catch (e) {
      folderProblems[link.path] = '$e';
      notifyListeners();
      return '$e';
    }
  }

  /// Adds the collection kept in the folder at [dir], and keeps it there.
  /// Returns what went wrong, or null.
  Future<String?> openCollectionDir(String dir, String grant) async {
    if (collections.any((c) => c.link?.path == dir)) {
      return 'That folder is already open as a collection.';
    }
    try {
      final read = await engine.readCollectionDir(dir: dir);
      final kept = await engine.readEnvironmentsDir(
        dir: dir,
        local: environments,
      );
      final linked = _linked(read, FolderLink(path: dir, grant: grant));
      _written[dir] = linked;
      await _stamp(dir);
      _takeEnvironments(dir, kept);
      _set(collections: [...collections, linked]);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Takes up each linked folder again after a start: the permission to
  /// use it, which a sandboxed app must ask for anew, and then whatever
  /// the files hold now.
  Future<void> restoreLinks(Folders folders) async {
    for (var i = 0; i < collections.length; i++) {
      final link = collections[i].link;
      if (link == null) continue;
      if (link.grant.isNotEmpty) {
        final path = await folders.restore(link.grant);
        // The folder may have been moved or renamed since.
        if (path != null && path != link.path) {
          _set(
            collections: [...collections]
              ..[i] = _linked(
                collections[i],
                FolderLink(path: path, grant: link.grant),
              ),
          );
        }
      }
      await reloadCollection(i);
    }
  }

  /// Writes every linked collection that has changed to its folder.
  Future<void> _writeLinked(Workspace saving) async {
    var changed = false;
    for (final collection in saving.collections) {
      final dir = collection.link?.path;
      if (dir == null) continue;
      final kept = keptIn(dir, saving.environments);
      final sameCollection = identical(_written[dir], collection);
      final sameEnvironments = _sameEnvironments(
        _writtenEnvironments[dir],
        kept,
      );
      if (sameCollection && sameEnvironments) continue;
      // One that could not be read is not written over what is there.
      if (folderProblems.containsKey(dir) && !_written.containsKey(dir)) {
        continue;
      }
      if (folderConflicts.contains(dir)) continue;
      // Files changed by a pull are not written over unseen.
      if (await _changedOnDisk(dir)) {
        folderConflicts.add(dir);
        folderProblems[dir] = _conflict;
        changed = true;
        continue;
      }
      try {
        if (!sameCollection) {
          await engine.writeCollectionDir(dir: dir, collection: collection);
          _written[dir] = collection;
        }
        if (!sameEnvironments) {
          await engine.writeEnvironmentsDir(dir: dir, environments: kept);
          _writtenEnvironments[dir] = kept;
        }
        await _stamp(dir);
        changed = folderProblems.remove(dir) != null || changed;
      } catch (e) {
        changed = folderProblems[dir] != '$e' || changed;
        folderProblems[dir] = '$e';
      }
    }
    if (changed) notifyListeners();
  }

  /// Writes the collection at [index] over its folder's files, though they
  /// changed on disk since they were read. Returns what went wrong.
  Future<String?> keepMine(int index) async {
    if (index < 0 || index >= collections.length) return null;
    final collection = collections[index];
    final dir = collection.link?.path;
    if (dir == null) return null;
    final kept = keptIn(dir);
    try {
      await engine.writeCollectionDir(dir: dir, collection: collection);
      await engine.writeEnvironmentsDir(dir: dir, environments: kept);
    } catch (e) {
      folderProblems[dir] = '$e';
      notifyListeners();
      return '$e';
    }
    _written[dir] = collection;
    _writtenEnvironments[dir] = kept;
    await _stamp(dir);
    folderConflicts.remove(dir);
    folderProblems.remove(dir);
    notifyListeners();
    return null;
  }

  /// Looks for linked folders whose files changed on disk, as when the app
  /// comes back to the front after a pull. One whose copy here has not
  /// changed since is read again; one where both changed is a conflict.
  Future<void> checkFolders() async {
    for (var i = 0; i < collections.length; i++) {
      final collection = collections[i];
      final dir = collection.link?.path;
      if (dir == null || folderConflicts.contains(dir)) continue;
      if (!await _changedOnDisk(dir)) continue;
      // The list may have changed while the disk was looked at.
      final at = collections.indexOf(collection);
      if (at < 0) continue;
      final unchangedHere =
          _written[dir] == collection &&
          _sameEnvironments(_writtenEnvironments[dir], keptIn(dir));
      if (unchangedHere) {
        await reloadCollection(at);
      } else {
        folderConflicts.add(dir);
        folderProblems[dir] = _conflict;
        notifyListeners();
      }
    }
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
        Collection(
          name: newCollectionName,
          variables: const [],
          items: [item],
          unreviewed: false,
        ),
      );
      _set(collections: all);
      return RequestRef(all.length - 1, const [0]);
    }
    final target = all[collection];
    all[collection] = Collection(
      name: target.name,
      variables: target.variables,
      link: target.link,
      unreviewed: target.unreviewed,
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
      link: target.link,
      unreviewed: target.unreviewed,
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
    final siblings = parent.isEmpty
        ? (ref.collection == RequestRef.noCollection
              ? requests
              : collections[ref.collection].items)
        : itemAt(RequestRef(ref.collection, parent))?.items ?? const [];
    insertItem(
      RequestRef(ref.collection, [...parent, 1 << 30]),
      Item(
        name: copyName(item.name, {for (final s in siblings) s.name}),
        request: item.request,
        items: item.items,
      ),
    );
  }

  /// The name for a copy of [name] that none of [taken] has: `Login copy`,
  /// then `Login copy 2`, and a copy of `Login copy` is `Login copy 2`
  /// rather than `Login copy copy`.
  static String copyName(String name, Set<String> taken) {
    final base = name.replaceFirst(RegExp(r' copy( \d+)?$'), '');
    var candidate = '$base copy';
    for (var n = 2; taken.contains(candidate); n++) {
      candidate = '$base copy $n';
    }
    return candidate;
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
      link: target.link,
      unreviewed: target.unreviewed,
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
    String? workingDir,
    String? workingDirGrant,
    bool? allowOutsideWorkingDir,
    bool? protectSecrets,
    int? historyLimit,
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
    workingDir: workingDir ?? this.workingDir,
    workingDirGrant: workingDirGrant ?? this.workingDirGrant,
    allowOutsideWorkingDir:
        allowOutsideWorkingDir ?? this.allowOutsideWorkingDir,
    protectSecrets: protectSecrets ?? this.protectSecrets,
    historyLimit: historyLimit ?? this.historyLimit,
  );
}
