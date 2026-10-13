import 'dart:async';

import 'package:flutter/material.dart' hide FormField;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reqorb/actions.dart';
import 'package:reqorb/auth_editor.dart';
import 'package:reqorb/body_editor.dart';
import 'package:reqorb/cookies_tab.dart';
import 'package:reqorb/environments.dart';
import 'package:reqorb/grpc_view.dart';
import 'package:reqorb/key_value_editor.dart';
import 'package:reqorb/request_draft.dart';
import 'package:reqorb/request_settings_editor.dart';
import 'package:reqorb/response_view.dart';
import 'package:reqorb/sidebar.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/src/rust/frb_generated.dart';
import 'package:reqorb/tests_editor.dart';
import 'package:reqorb/theme.dart';
import 'package:reqorb/workspace_store.dart';
import 'package:reqorb/ws_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final directory = await getApplicationSupportDirectory();
  final store = WorkspaceStore('${directory.path}/workspace.json');
  await store.load();
  runApp(ReqorbApp(store: store));
}

class ReqorbApp extends StatelessWidget {
  const ReqorbApp({super.key, required this.store});

  final WorkspaceStore store;

  @override
  Widget build(BuildContext context) {
    // Rebuilt when settings change, so a new theme applies immediately.
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: 'reqorb',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: switch (store.settings.theme) {
          AppTheme.system => ThemeMode.system,
          AppTheme.light => ThemeMode.light,
          AppTheme.dark => ThemeMode.dark,
        },
        home: RequestPage(store: store),
      ),
    );
  }
}

const _methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];

/// Other kinds of request, chosen where an HTTP method would be.
const _protocols = ['WS', 'GRPC'];

const _sidebarWidth = 280.0;

/// Dropdown value meaning "no environment"; real names are never empty.
const _noEnvironment = '';

class RequestPage extends StatefulWidget {
  const RequestPage({super.key, required this.store});

  final WorkspaceStore store;

  @override
  State<RequestPage> createState() => _RequestPageState();
}

class _RequestPageState extends State<RequestPage> {
  final _scaffold = GlobalKey<ScaffoldState>();

  /// The request in the editor. The names below are shorthand for its parts.
  final _draft = RequestDraft(url: 'https://httpbin.org/get');

  TextEditingController get _url => _draft.url;
  TextEditingController get _headers => _draft.headers;
  TextEditingController get _tests => _draft.tests;
  TextEditingController get _captures => _draft.captures;
  TextEditingController get _body => _draft.body;
  TextEditingController get _urlEncoded => _draft.urlEncoded;
  TextEditingController get _binary => _draft.binary;
  TextEditingController get _params => _draft.params;

  String get _method => _draft.method;
  set _method(String value) => _draft.method = value;
  BodyMode get _bodyMode => _draft.bodyMode;
  set _bodyMode(BodyMode value) => _draft.bodyMode = value;
  List<FormField> get _formData => _draft.formData;
  set _formData(List<FormField> value) => _draft.formData = value;
  Auth? get _auth => _draft.auth;
  set _auth(Auth? value) => _draft.auth = value;
  RequestSettings? get _settings => _draft.settings;
  set _settings(RequestSettings? value) => _draft.settings = value;
  String? get _grpcMethod => _draft.grpcMethod;
  set _grpcMethod(String? value) => _draft.grpcMethod = value;
  String? get _protoPath => _draft.protoPath;
  set _protoPath(String? value) => _draft.protoPath = value;
  int get _generation => _draft.generation;

  /// Key-value tabs currently in Bulk Edit mode.
  final _bulk = <String>{};
  bool _sending = false;
  Sent? _sent;
  String? _error;

  /// The saved request being edited, if the editor was opened from one.
  RequestRef? _origin;

  /// Whether the docked sidebar is hidden to give the editor more room.
  bool _sidebarCollapsed = false;

  /// Share of the space the request editor takes; the response has the rest.
  double _split = 0.4;

  final _urlFocus = FocusNode();

  /// The name given to a request that has not been saved yet.
  String? _draftName;

  /// Whether the title is being edited in place.
  bool _editingTitle = false;
  final _titleText = TextEditingController();
  final _titleFocus = FocusNode();

  /// Identifies the send in flight, so a cancelled one is ignored on return.
  int _sendId = 0;

  /// Notifies on any edit to the request, for the title and the tab badges.
  Listenable get _edits => _draft;

  void _touch() => _draft.touch();

  WorkspaceStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    // Clicking away from the title keeps what was typed.
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editingTitle) _commitTitle();
    });
  }

  @override
  void dispose() {
    _draft.dispose();
    final socket = _socket;
    if (socket != null) wsClose(id: socket);
    _socketEvents?.cancel();
    _urlFocus.dispose();
    _titleText.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  List<Header> _parseHeaders() => _draft.parseHeaders();

  /// Whether the editor holds a WebSocket rather than an HTTP request.
  bool get _isWs => _method == 'WS';

  // ------------------------------------------------------------ websocket

  static int _nextSocket = 1;

  /// The connection this page opened, if any.
  int? _socket;
  StreamSubscription<WsEvent>? _socketEvents;
  bool _wsOpen = false;
  bool _wsConnecting = false;
  final _wsLog = <WsEntry>[];

  void _wsConnect() {
    final request = _request();
    if (request.url.isEmpty) {
      _urlFocus.requestFocus();
      showMessage(context, 'Enter an address to connect to');
      return;
    }
    final url = request.url.contains('://') || request.url.startsWith('{{')
        ? request.url
        : 'ws://${request.url}';
    final id = _nextSocket++;
    setState(() {
      _socket = id;
      _wsConnecting = true;
    });
    _socketEvents =
        wsOpen(
          id: id,
          request: Request(
            method: 'GET',
            url: url,
            headers: request.headers,
            form: const [],
            auth: request.auth,
            settings: request.settings,
            tests: const [],
            captures: const [],
          ),
          variables: _store.variablesFor(_origin?.collection),
        ).listen(
          (event) {
            if (!mounted || id != _socket) return;
            setState(() {
              _wsConnecting = false;
              if (event.kind == WsEventKind.open) _wsOpen = true;
              if (event.kind == WsEventKind.closed ||
                  event.kind == WsEventKind.error) {
                _wsOpen = false;
              }
              _wsLog.add(WsEntry.received(event));
            });
          },
          onDone: () {
            if (!mounted || id != _socket) return;
            setState(() {
              _wsOpen = false;
              _wsConnecting = false;
            });
          },
        );
  }

  /// Closes the connection, or gives up on one still being opened.
  void _wsDisconnect() {
    final id = _socket;
    if (id == null) return;
    if (!wsClose(id: id)) {
      _socketEvents?.cancel();
      setState(() {
        _socket = null;
        _wsOpen = false;
        _wsConnecting = false;
      });
    }
  }

  void _wsSend() {
    final id = _socket;
    final text = _body.text;
    if (id == null || !_wsOpen || text.isEmpty) return;
    if (wsSend(id: id, text: text)) {
      setState(() => _wsLog.add(WsEntry.sent(text)));
    }
  }

  /// Drops the connection and its log, as when another request is opened.
  void _wsReset() {
    final id = _socket;
    if (id != null) wsClose(id: id);
    _socketEvents?.cancel();
    _socket = null;
    _socketEvents = null;
    _wsOpen = false;
    _wsConnecting = false;
    _wsLog.clear();
  }

  // ----------------------------------------------------------------- grpc

  bool get _isGrpc => _method == 'GRPC';

  /// The server's methods, once loaded by reflection or from a file.
  GrpcSchema? _grpcSchema;

  bool _grpcBusy = false;
  GrpcReply? _grpcReply;
  String? _grpcError;

  void _grpcReset() {
    _grpcSchema = null;
    _grpcMethod = null;
    _protoPath = null;
    _grpcBusy = false;
    _grpcReply = null;
    _grpcError = null;
  }

  /// Chooses a method, offering its blank message unless one is being written.
  void _grpcSelect(String path) {
    final methods = _grpcSchema?.methods ?? const <GrpcMethod>[];
    final examples = {for (final m in methods) m.example.trim()};
    setState(() {
      _grpcMethod = path;
      final text = _body.text.trim();
      if (text.isEmpty || text == '{}' || examples.contains(text)) {
        _body.text =
            methods.where((m) => m.path == path).firstOrNull?.example ?? '';
      }
    });
    _touch();
  }

  /// Loads the methods from [proto], or from the server when it is null.
  /// Returns whether they are now available.
  Future<bool> _grpcLoad({String? proto}) async {
    final request = _request();
    if (proto == null && request.url.isEmpty) {
      _urlFocus.requestFocus();
      showMessage(context, 'Enter the server address first');
      return false;
    }
    final generation = _generation;
    setState(() {
      _grpcBusy = true;
      _grpcError = null;
    });
    try {
      final schema = proto != null
          ? await grpcLoadProto(path: proto)
          : await grpcReflect(
              url: request.url,
              metadata: request.headers,
              auth: request.auth,
              variables: _store.variablesFor(_origin?.collection),
            );
      // Another request may have been opened while this was loading.
      if (!mounted || generation != _generation) return false;
      setState(() {
        _grpcSchema = schema;
        _protoPath = proto;
        _grpcBusy = false;
      });
      final known = schema.methods.any((m) => m.path == _grpcMethod);
      if (!known && schema.methods.isNotEmpty) {
        _grpcSelect(schema.methods.first.path);
      }
      return true;
    } catch (e) {
      if (!mounted || generation != _generation) return false;
      setState(() {
        _grpcBusy = false;
        _grpcReply = null;
        _grpcError = e.toString();
      });
      return false;
    }
  }

  Future<void> _grpcChooseProto() async {
    final path = await pickFilePath();
    if (path != null && mounted) await _grpcLoad(proto: path);
  }

  Future<void> _grpcInvoke() async {
    if (_grpcBusy) return;
    // Loading the methods first saves a step the first time round.
    if (_grpcSchema == null && !await _grpcLoad(proto: _protoPath)) return;
    final schema = _grpcSchema;
    final method = _grpcMethod;
    if (schema == null || !mounted) return;
    if (method == null) {
      showMessage(context, 'Choose a method to call');
      return;
    }
    final request = _request();
    final generation = _generation;
    setState(() {
      _grpcBusy = true;
      _grpcError = null;
    });
    try {
      final reply = await grpcCall(
        call: GrpcCall(
          url: request.url,
          method: method,
          messages: grpcMessages(_body.text),
          metadata: request.headers,
          auth: request.auth,
          descriptors: schema.descriptors,
        ),
        variables: _store.variablesFor(_origin?.collection),
      );
      if (!mounted || generation != _generation) return;
      setState(() => _grpcReply = reply);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _grpcReply = null;
        _grpcError = e.toString();
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _grpcBusy = false);
      }
    }
  }

  /// What the main button and its shortcut do for the kind of request open.
  void _primary() {
    if (_isGrpc) {
      _grpcInvoke();
    } else if (!_isWs) {
      _send();
    } else if (_wsOpen) {
      _wsSend();
    } else if (!_wsConnecting) {
      _wsConnect();
    }
  }

  /// The request as typed, before variables are substituted.
  Request _request() => _draft.toRequest();

  String? _rawLanguage() => _draft.rawLanguage();

  void _setRawLanguage(String name) =>
      setState(() => _draft.setRawLanguage(name));

  /// Whether the open request differs from its saved copy.
  bool get _dirty => _origin != null && _draft.dirty;

  /// The open request's name: its saved one, or the one typed for a draft.
  String? get _name {
    final origin = _origin;
    return (origin == null ? null : _store.itemAt(origin)?.name) ?? _draftName;
  }

  void _editTitle() {
    final name = _name ?? '';
    _titleText
      ..text = name
      ..selection = TextSelection(baseOffset: 0, extentOffset: name.length);
    setState(() => _editingTitle = true);
  }

  /// Renames the saved request, or names the draft for when it is saved.
  void _commitTitle() {
    if (!_editingTitle) return;
    final name = _titleText.text.trim();
    final origin = _origin;
    setState(() {
      _editingTitle = false;
      if (name.isEmpty) return;
      if (origin != null && _store.itemAt(origin) != null) {
        _store.renameItem(origin, name);
      } else {
        _draftName = name;
      }
    });
  }

  /// Runs [then], which replaces what is in the editor, after making sure
  /// unsaved edits to a saved request are not lost without being asked.
  Future<void> _leave(VoidCallback then) async {
    final origin = _origin;
    final name = _name;
    if (!_dirty || origin == null) return then();
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save changes?'),
        content: Text(
          '"$name" has changes that have not been saved. '
          'Discarding them cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('discard-changes'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Discard'),
          ),
          FilledButton(
            key: const Key('save-changes'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (save == null || !mounted) return;
    if (save) _store.updateRequest(origin, _request());
    then();
  }

  void _open(RequestRef ref) {
    final request = _store.itemAt(ref)?.request;
    if (request == null) return;
    setState(() {
      _wsReset();
      _grpcReset();
      _draft.load(request);
      _origin = ref;
      _sent = null;
      _error = null;
      _draftName = null;
      _editingTitle = false;
    });
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState!.closeDrawer();
    }
  }

  /// Clears the editor for a request that is not saved anywhere yet.
  void _newRequest() {
    setState(() {
      _wsReset();
      _grpcReset();
      _origin = null;
      _draft.clear();
      _sent = null;
      _error = null;
      _draftName = null;
      _editingTitle = false;
    });
    _urlFocus.requestFocus();
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState!.closeDrawer();
    }
  }

  Future<void> _send() async {
    final request = _request();
    if (_sending) return;
    if (request.url.isEmpty) {
      // Say why nothing happened, and put the cursor where the fix goes.
      _urlFocus.requestFocus();
      showMessage(context, 'Enter a URL to send the request');
      return;
    }
    // A leading variable usually holds the scheme already.
    final url = request.url.contains('://') || request.url.startsWith('{{')
        ? request.url
        : 'http://${request.url}';

    final id = ++_sendId;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final sent = await sendRequest(
        request: Request(
          method: request.method,
          url: url,
          headers: request.headers,
          body: request.body,
          bodyMode: request.bodyMode,
          form: request.form,
          auth: request.auth,
          settings: request.settings,
          tests: request.tests,
          captures: request.captures,
        ),
        variables: _store.variablesFor(_origin?.collection),
        settings: _store.settings,
        cookies: _store.cookies,
      );
      // Cancelled, or overtaken by a later send.
      if (id != _sendId) return;
      // Keep whatever the server set, even if this page has gone away.
      _store.setCookies(sent.cookies);
      _store.addExchanges(sent.exchanges);
      _store.capture(sent.captured);
      if (!mounted) return;
      setState(() => _sent = sent);
    } catch (e) {
      if (!mounted || id != _sendId) return;
      setState(() {
        _sent = null;
        _error = e.toString();
      });
    } finally {
      if (mounted && id == _sendId) setState(() => _sending = false);
    }
  }

  /// Stops waiting for the request in flight; its response is discarded.
  void _cancel() {
    _sendId++;
    setState(() => _sending = false);
  }

  Future<void> _save() async {
    final request = _request();
    final origin = _origin;
    if (origin != null && _store.itemAt(origin)?.request != null) {
      _store.updateRequest(origin, request);
      setState(_draft.markSaved);
      showMessage(context, 'Saved');
      return;
    }
    final path = Uri.tryParse(request.url)?.path ?? '';
    final target = await showDialog<_SaveTarget>(
      context: context,
      builder: (_) => _SaveDialog(
        collections: [for (final c in _store.collections) c.name],
        suggestedName:
            _draftName ?? '${request.method} ${path.isEmpty ? '/' : path}',
      ),
    );
    if (target == null || !mounted) return;
    final ref = switch (target.destination) {
      _SaveTarget.standalone => _store.addStandaloneRequest(
        target.name,
        request,
      ),
      _SaveTarget.newCollection => _store.addRequest(
        collection: null,
        newCollectionName: target.newCollectionName,
        name: target.name,
        request: request,
      ),
      final index => _store.addRequest(
        collection: index,
        newCollectionName: '',
        name: target.name,
        request: request,
      ),
    };
    setState(() {
      _origin = ref;
      _draft.markSaved();
      _draftName = null;
    });
  }

  void _manageEnvironments() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => EnvironmentsPage(store: _store),
      ),
    );
  }

  /// Hides or shows the docked sidebar; in drawer mode, opens or closes it.
  void _toggleSidebar({required bool docked}) {
    if (docked) {
      setState(() => _sidebarCollapsed = !_sidebarCollapsed);
    } else if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState!.closeDrawer();
    } else {
      _scaffold.currentState?.openDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          // The sidebar is docked when there is room, otherwise a drawer.
          final docked = constraints.maxWidth >= 720;
          final collapsed = docked && _sidebarCollapsed;
          void toggle() => _toggleSidebar(docked: docked);
          final sidebar = Sidebar(
            store: _store,
            selected: _origin,
            onOpen: (ref) {
              // The open request needs no reloading, and reloading it would
              // throw away whatever has been typed since.
              if (ref != _origin) _leave(() => _open(ref));
            },
            onNewRequest: () => _leave(_newRequest),
            onRemoved: () => setState(() {
              _origin = null;
              _draft.saved = null;
            }),
            onCollapse: docked ? toggle : null,
          );
          const width = _sidebarWidth + 1;
          return CallbackShortcuts(
            bindings: {
              // Each shortcut works with Command on macOS and Control elsewhere.
              for (final (key, action) in [
                (LogicalKeyboardKey.keyB, toggle),
                (LogicalKeyboardKey.enter, _primary),
                (LogicalKeyboardKey.keyS, _save),
                (LogicalKeyboardKey.keyN, () => _leave(_newRequest)),
                (LogicalKeyboardKey.keyL, _urlFocus.requestFocus),
              ]) ...{
                SingleActivator(key, meta: true): action,
                SingleActivator(key, control: true): action,
              },
            },
            child: Scaffold(
              key: _scaffold,
              drawer: docked ? null : Drawer(child: SafeArea(child: sidebar)),
              body: SafeArea(
                child: Row(
                  children: [
                    if (docked)
                      // The sidebar keeps its width and slides out of view,
                      // so its contents never reflow while animating.
                      ClipRect(
                        child: AnimatedContainer(
                          key: const Key('sidebar'),
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          width: collapsed ? 0 : width,
                          child: OverflowBox(
                            alignment: Alignment.centerRight,
                            minWidth: width,
                            maxWidth: width,
                            child: ExcludeFocus(
                              excluding: collapsed,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: _sidebarWidth,
                                    child: sidebar,
                                  ),
                                  const VerticalDivider(width: 1),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: _main(
                        context,
                        showMenu: !docked || collapsed,
                        onMenu: toggle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// What each request tab currently holds, shown beside its label.
  _Badges _badges() => (
    params: [
      for (final line in _params.text.split('\n'))
        if (parseKeyValueLine(line) != null) line,
    ].length,
    headers: _parseHeaders().length,
    body: _isWs || _isGrpc ? _body.text.isNotEmpty : _bodyMode != BodyMode.none,
    auth: _auth != null,
    cookies: _store.cookies.length,
    settings: _settings != null,
    tests: linesOf(_tests.text).length + linesOf(_captures.text).length,
  );

  /// Where the open request is saved and whether it has unsaved edits.
  /// Double-clicking or long-pressing the name edits it in place.
  Widget _title(ThemeData theme) {
    final scheme = theme.colorScheme;
    final origin = _origin;
    final item = origin == null ? null : _store.itemAt(origin);
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    const strong = TextStyle(fontWeight: FontWeight.w600);
    final name = _name;
    final collection =
        item != null &&
            origin!.collection >= 0 &&
            origin.collection < _store.collections.length
        ? '${_store.collections[origin.collection].name}  /  '
        : null;

    final Widget label;
    if (_editingTitle) {
      label = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (collection != null) Text(collection, style: muted),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: CallbackShortcuts(
                bindings: {
                  // Escape leaves the name as it was.
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      setState(() => _editingTitle = false),
                },
                child: TextField(
                  key: const Key('title-field'),
                  controller: _titleText,
                  focusNode: _titleFocus,
                  autofocus: true,
                  style: theme.textTheme.bodyMedium?.merge(strong),
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Request name',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                  ),
                  onSubmitted: (_) => _commitTitle(),
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      final text = Text.rich(
        TextSpan(
          children: [
            if (collection != null) TextSpan(text: collection, style: muted),
            TextSpan(
              text: name ?? 'Untitled request',
              style: name == null ? muted : strong,
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      final target = GestureDetector(
        key: const Key('title'),
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _editTitle,
        onLongPress: _editTitle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: text,
        ),
      );
      // The hint wraps the gesture target, because a tooltip inside it would
      // win the long press; on touch screens it is left out altogether.
      label = isDesktop
          ? Tooltip(message: 'Double-click to rename', child: target)
          : target;
    }
    return Row(
      children: [
        Flexible(child: label),
        if (_dirty)
          Tooltip(
            message: 'Unsaved changes (${shortcutModifier}S to save)',
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 8, color: scheme.primary),
                  const SizedBox(width: 5),
                  Text(
                    'Edited',
                    key: const Key('unsaved'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _environmentPicker(ThemeData theme) {
    final scheme = theme.colorScheme;
    final active = _store.activeEnvironment;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.layers_outlined,
              size: 16,
              // Coloured while an environment is supplying variables.
              color: active == null ? scheme.outline : scheme.primary,
            ),
            const SizedBox(width: 6),
            DropdownButton<String>(
              key: const Key('environment'),
              value: active ?? _noEnvironment,
              isDense: true,
              style: theme.textTheme.bodyMedium,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(
                  value: _noEnvironment,
                  child: Text('No environment'),
                ),
                for (final e in _store.environments)
                  DropdownMenuItem(value: e.name, child: Text(e.name)),
              ],
              onChanged: (name) => _store.setActiveEnvironment(
                name == _noEnvironment ? null : name,
              ),
            ),
            IconButton(
              key: const Key('manage-environments'),
              tooltip: 'Manage environments',
              iconSize: 18,
              // Kept full size on touch screens, where it is hard to hit.
              visualDensity: isDesktop ? VisualDensity.compact : null,
              icon: const Icon(Icons.tune),
              onPressed: _manageEnvironments,
            ),
          ],
        ),
      ),
    );
  }

  /// The method and URL in one field, as they are read together.
  Widget _urlBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: _urlFocus,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _urlFocus.hasFocus ? scheme.primary : scheme.outlineVariant,
            width: 1.5,
          ),
        ),
        child: child,
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 2),
            child: DropdownButton<String>(
              key: const Key('method'),
              value: _method,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                // Imported requests may use a method outside the usual list.
                for (final m in {..._methods, ..._protocols, _method})
                  DropdownMenuItem(
                    value: m,
                    child: Text(
                      m,
                      style: mono.copyWith(
                        color: methodColor(m, theme.brightness),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
              onChanged: (m) => setState(() {
                // Leaving a WebSocket for another kind ends its connection.
                if (_isWs && m != _method) _wsReset();
                if (_isGrpc && m != _method) _grpcReset();
                _method = m ?? _method;
              }),
            ),
          ),
          SizedBox(
            height: 22,
            child: VerticalDivider(width: 9, color: scheme.outlineVariant),
          ),
          Expanded(
            child: TextField(
              key: const Key('url'),
              focusNode: _urlFocus,
              smartQuotesType: SmartQuotesType.disabled,
              smartDashesType: SmartDashesType.disabled,
              controller: _url,
              autocorrect: false,
              keyboardType: TextInputType.url,
              style: mono,
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 11,
                ),
                hintText: 'Enter a URL, or paste one: {{base_url}}/users',
              ),
              onSubmitted: (_) => _isWs ? _wsConnect() : _primary(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _main(
    BuildContext context, {
    required bool showMenu,
    required VoidCallback onMenu,
  }) {
    final theme = Theme.of(context);
    final request = _RequestEditor(
      params: _params,
      headers: _headers,
      tests: TestsEditor(tests: _tests, captures: _captures),
      edits: _edits,
      badges: _badges,
      message: _isGrpc
          ? GrpcComposer(
              controller: _body,
              schema: _grpcSchema,
              method: _grpcMethod,
              protoPath: _protoPath,
              loading: _grpcBusy && _grpcSchema == null,
              onMethod: _grpcSelect,
              onReflect: _grpcLoad,
              onChooseProto: _grpcChooseProto,
            )
          : !_isWs
          ? null
          : _WsComposer(controller: _body, connected: _wsOpen, onSend: _wsSend),
      body: BodyEditor(
        mode: _bodyMode,
        onModeChanged: (mode) => setState(() => _bodyMode = mode),
        raw: _body,
        rawLanguage: _rawLanguage(),
        onRawLanguageChanged: _setRawLanguage,
        urlEncoded: _urlEncoded,
        urlEncodedBulk: _bulk.contains('urlencoded'),
        onUrlEncodedBulkChanged: (bulk) => setState(() {
          bulk ? _bulk.add('urlencoded') : _bulk.remove('urlencoded');
        }),
        formData: FormDataEditor(
          key: ValueKey(_generation),
          fields: _formData,
          onChanged: (fields) {
            _formData = fields;
            _touch();
          },
        ),
        binary: _binary,
      ),
      cookies: CookiesTab(store: _store, currentUrl: () => _url.text),
      settings: RequestSettingsEditor(
        key: ValueKey(_generation),
        settings: _settings,
        appHttpMode: _store.settings.httpMode,
        onChanged: (settings) {
          _settings = settings;
          _touch();
        },
      ),
      bulk: _bulk,
      onBulkChanged: (name, bulk) => setState(() {
        bulk ? _bulk.add(name) : _bulk.remove(name);
      }),
      auth: AuthEditor(
        key: ValueKey(_generation),
        auth: _auth,
        // No rebuild of the form needed: it already shows what was typed.
        onChanged: (auth) {
          _auth = auth;
          _touch();
        },
      ),
    );
    final Widget response = _isGrpc
        ? GrpcReplyView(
            reply: _grpcReply,
            error: _grpcError,
            calling: _grpcBusy && _grpcSchema != null,
          )
        : _isWs
        ? WsLogView(
            entries: _wsLog,
            connected: _wsOpen,
            connecting: _wsConnecting,
            onClear: () => setState(_wsLog.clear),
          )
        : ResponseView(
            sent: _sent,
            error: _error ?? _store.error,
            errorTitle: _error != null
                ? 'The request could not be sent'
                : 'The workspace could not be read or saved',
            sending: _sending,
            sessionSize: _store.session.length,
            onExportSession: () => exportSessionHar(context, _store),
          );
    // A text label needs room; below that the icon alone has to do.
    final roomy = MediaQuery.sizeOf(context).width >= 1000;

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(showMenu ? 4 : 16, 8, 12, 0),
          child: Row(
            children: [
              if (showMenu)
                IconButton(
                  key: const Key('show-sidebar'),
                  tooltip: 'Show sidebar (${shortcutModifier}B)',
                  icon: const Icon(Icons.menu),
                  onPressed: onMenu,
                ),
              Expanded(
                child: ListenableBuilder(
                  listenable: _edits,
                  builder: (context, _) => _title(theme),
                ),
              ),
              const SizedBox(width: 12),
              _environmentPicker(theme),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: SizedBox(
            height: 42,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _urlBar(theme)),
                const SizedBox(width: 8),
                if (_isWs && (_wsOpen || _wsConnecting))
                  FilledButton.tonal(
                    key: const Key('send'),
                    onPressed: _wsDisconnect,
                    child: Text(_wsOpen ? 'Disconnect' : 'Cancel'),
                  )
                else if (_isWs)
                  FilledButton(
                    key: const Key('send'),
                    onPressed: _wsConnect,
                    child: const Text('Connect'),
                  )
                else if (_isGrpc)
                  FilledButton(
                    key: const Key('send'),
                    onPressed: _grpcBusy ? null : _grpcInvoke,
                    child: const Text('Invoke'),
                  )
                else if (_sending)
                  FilledButton.tonal(
                    key: const Key('send'),
                    onPressed: _cancel,
                    child: const Text('Cancel'),
                  )
                else
                  Tooltip(
                    message: 'Send ($shortcutModifier↵)',
                    child: FilledButton(
                      key: const Key('send'),
                      onPressed: _send,
                      child: const Text('Send'),
                    ),
                  ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Save request (${shortcutModifier}S)',
                  child: roomy
                      ? OutlinedButton.icon(
                          key: const Key('save'),
                          onPressed: _save,
                          icon: const Icon(Icons.save_outlined, size: 18),
                          label: const Text('Save'),
                        )
                      : OutlinedButton(
                          key: const Key('save'),
                          onPressed: _save,
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(44, 42),
                          ),
                          child: const Icon(Icons.save_outlined, size: 18),
                        ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => _SplitView(
              // Side by side when wide, stacked otherwise.
              axis: constraints.maxWidth >= 900
                  ? Axis.horizontal
                  : Axis.vertical,
              fraction: _split,
              onChanged: (fraction) => setState(() => _split = fraction),
              first: request,
              second: response,
            ),
          ),
        ),
      ],
    );
  }
}

/// Two panes with a divider between them that can be dragged to resize.
class _SplitView extends StatelessWidget {
  const _SplitView({
    required this.axis,
    required this.fraction,
    required this.onChanged,
    required this.first,
    required this.second,
  });

  final Axis axis;

  /// Share of the space given to [first].
  final double fraction;
  final ValueChanged<double> onChanged;
  final Widget first;
  final Widget second;

  static const _handle = 7.0;
  static const _minPane = 120.0;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total =
            (horizontal ? constraints.maxWidth : constraints.maxHeight) -
            _handle;
        var size = total * fraction;
        // Neither pane may be dragged out of reach.
        if (total > _minPane * 2) {
          size = size.clamp(_minPane, total - _minPane);
        }
        final line = horizontal
            ? const VerticalDivider(width: 1)
            : const Divider(height: 1);
        return Flex(
          direction: axis,
          children: [
            SizedBox(
              width: horizontal ? size : null,
              height: horizontal ? null : size,
              child: first,
            ),
            MouseRegion(
              cursor: horizontal
                  ? SystemMouseCursors.resizeColumn
                  : SystemMouseCursors.resizeRow,
              child: GestureDetector(
                key: const Key('split-handle'),
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (drag) {
                  if (total <= 0) return;
                  final moved = horizontal ? drag.delta.dx : drag.delta.dy;
                  onChanged(((size + moved) / total).clamp(0.1, 0.9));
                },
                onDoubleTap: () => onChanged(0.4),
                child: SizedBox(
                  width: horizontal ? _handle : null,
                  height: horizontal ? null : _handle,
                  child: Center(child: line),
                ),
              ),
            ),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

/// Where the save dialog says a new request should go.
class _SaveTarget {
  const _SaveTarget(this.name, this.destination, this.newCollectionName);

  /// Save on its own, outside any collection.
  static const standalone = -2;

  /// Create a collection named [newCollectionName] and save into it.
  static const newCollection = -1;

  final String name;

  /// Index of an existing collection, or one of the constants above.
  final int destination;
  final String newCollectionName;
}

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({required this.collections, required this.suggestedName});

  final List<String> collections;
  final String suggestedName;

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late final _name = TextEditingController(text: widget.suggestedName);
  final _newCollection = TextEditingController();
  int _destination = _SaveTarget.standalone;

  @override
  void dispose() {
    _name.dispose();
    _newCollection.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final newName = _newCollection.text.trim();
    final needsName = _destination == _SaveTarget.newCollection;
    if (name.isEmpty || (needsName && newName.isEmpty)) return;
    Navigator.pop(context, _SaveTarget(name, _destination, newName));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save request'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('save-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                isDense: false,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: const Key('save-destination'),
              isExpanded: true,
              initialValue: _destination,
              decoration: const InputDecoration(
                labelText: 'Save to',
                isDense: false,
              ),
              items: [
                const DropdownMenuItem(
                  value: _SaveTarget.standalone,
                  child: Text('No collection'),
                ),
                for (var i = 0; i < widget.collections.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(widget.collections[i]),
                  ),
                const DropdownMenuItem(
                  value: _SaveTarget.newCollection,
                  child: Text('New collection…'),
                ),
              ],
              onChanged: (i) =>
                  setState(() => _destination = i ?? _destination),
            ),
            if (_destination == _SaveTarget.newCollection) ...[
              const SizedBox(height: 16),
              TextField(
                key: const Key('save-collection'),
                controller: _newCollection,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Collection name',
                  isDense: false,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-confirm'),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

typedef _Badges = ({
  int params,
  int headers,
  bool body,
  bool auth,
  int cookies,
  bool settings,
  int tests,
});

class _RequestEditor extends StatelessWidget {
  const _RequestEditor({
    required this.params,
    required this.headers,
    required this.tests,
    required this.body,
    required this.auth,
    required this.cookies,
    required this.settings,
    required this.bulk,
    required this.onBulkChanged,
    required this.edits,
    required this.badges,
    this.message,
  });

  final TextEditingController params;
  final TextEditingController headers;
  final Widget body;
  final Widget auth;
  final Widget cookies;
  final Widget settings;
  final Widget tests;

  /// Names of the key-value tabs currently shown as text.
  final Set<String> bulk;
  final void Function(String name, bool bulk) onBulkChanged;

  /// Notifies when the request is edited, so the tab badges stay current.
  final Listenable edits;
  final _Badges Function() badges;

  /// Replaces the Body tab for requests that send messages instead.
  final Widget? message;

  /// Forms read better at a fixed measure than stretched across a wide pane.
  static Widget _form(Widget child) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: SizedBox.expand(child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: edits,
            builder: (context, _) {
              final has = badges();
              return TabBar(
                // Tabs sit together at the start instead of stretching out.
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(
                    key: const Key('params-tab'),
                    height: 40,
                    child: _TabLabel('Params', count: has.params),
                  ),
                  Tab(
                    key: const Key('headers-tab'),
                    height: 40,
                    child: _TabLabel('Headers', count: has.headers),
                  ),
                  Tab(
                    key: const Key('body-tab'),
                    height: 40,
                    child: _TabLabel(
                      message == null ? 'Body' : 'Message',
                      set: has.body,
                    ),
                  ),
                  Tab(
                    key: const Key('auth-tab'),
                    height: 40,
                    child: _TabLabel('Auth', set: has.auth),
                  ),
                  Tab(
                    key: const Key('cookies-tab'),
                    height: 40,
                    child: _TabLabel('Cookies', count: has.cookies),
                  ),
                  Tab(
                    key: const Key('request-settings-tab'),
                    height: 40,
                    child: _TabLabel('Settings', set: has.settings),
                  ),
                  Tab(
                    key: const Key('tests-tab'),
                    height: 40,
                    child: _TabLabel('Tests', count: has.tests),
                  ),
                ],
              );
            },
          ),
          Expanded(
            child: TabBarView(
              children: [
                KeyValueEditor(
                  controller: params,
                  name: 'params',
                  bulk: bulk.contains('params'),
                  onBulkChanged: (value) => onBulkChanged('params', value),
                  separator: ':',
                  bulkHint: 'page:1\nlimit:{{pageSize}}',
                ),
                KeyValueEditor(
                  controller: headers,
                  name: 'headers',
                  bulk: bulk.contains('headers'),
                  onBulkChanged: (value) => onBulkChanged('headers', value),
                  bulkHint: 'Accept: application/json\nX-Request-Id: {{id}}',
                ),
                message ?? body,
                _form(auth),
                cookies,
                _form(settings),
                _form(tests),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A tab's name with a count, or a dot when the tab holds something that
/// cannot be counted, so filled tabs can be spotted without opening them.
class _TabLabel extends StatelessWidget {
  const _TabLabel(this.label, {this.count = 0, this.set = false});

  final String label;
  final int count;
  final bool set;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (count > 0) ...[
          const SizedBox(width: 5),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ] else if (set) ...[
          const SizedBox(width: 5),
          Icon(Icons.circle, size: 6, color: scheme.primary),
        ],
      ],
    );
  }
}

/// The Message tab of a WebSocket: what to send next, and a button for it.
class _WsComposer extends StatelessWidget {
  const _WsComposer({
    required this.controller,
    required this.connected,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool connected;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: TextField(
            key: const Key('ws-message'),
            controller: controller,
            maxLines: null,
            expands: true,
            autocorrect: false,
            enableSuggestions: false,
            smartQuotesType: SmartQuotesType.disabled,
            smartDashesType: SmartDashesType.disabled,
            textAlignVertical: TextAlignVertical.top,
            style: mono,
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.all(12),
              hintText: 'Message to send, such as {"type": "ping"}',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  connected
                      ? 'Sent as a text message. '
                            '${isDesktop ? '$shortcutModifier↵ sends it.' : ''}'
                      : 'Connect first, then send messages from here.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              FilledButton.tonal(
                key: const Key('ws-send'),
                onPressed: connected ? onSend : null,
                child: const Text('Send message'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
