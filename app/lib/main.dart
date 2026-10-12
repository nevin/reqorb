import 'dart:convert';

import 'package:flutter/material.dart' hide FormField;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reqorb/actions.dart';
import 'package:reqorb/auth_editor.dart';
import 'package:reqorb/body_editor.dart';
import 'package:reqorb/cookies_tab.dart';
import 'package:reqorb/environments.dart';
import 'package:reqorb/key_value_editor.dart';
import 'package:reqorb/request_settings_editor.dart';
import 'package:reqorb/sidebar.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/src/rust/frb_generated.dart';
import 'package:reqorb/workspace_store.dart';

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
    const seed = Color(0xFF5B5BD6);
    // Rebuilt when settings change, so a new theme applies immediately.
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: 'reqorb',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: seed),
        darkTheme: ThemeData(
          colorSchemeSeed: seed,
          brightness: Brightness.dark,
        ),
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
const _mono = TextStyle(fontFamily: 'Menlo', fontSize: 13, height: 1.4);

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
  final _url = TextEditingController(text: 'https://httpbin.org/get');
  final _headers = TextEditingController();
  final _body = TextEditingController();

  /// Which kind of body the request has; [_body] holds the raw text.
  BodyMode _bodyMode = BodyMode.none;

  /// Url-encoded fields as `key: value` lines.
  final _urlEncoded = TextEditingController();

  /// Form-data fields, kept in step by the form-data table.
  List<FormField> _formData = const [];

  /// Path of the file sent as a binary body.
  final _binary = TextEditingController();

  /// The URL's query string as `key:value` lines, for the Params tab.
  final _params = TextEditingController();

  /// Guards the two listeners that keep [_url] and [_params] in step.
  bool _syncing = false;

  /// Key-value tabs currently in Bulk Edit mode.
  final _bulk = <String>{};
  String _method = 'GET';
  bool _sending = false;
  Sent? _sent;
  String? _error;

  /// The saved request being edited, if the editor was opened from one.
  RequestRef? _origin;

  /// How the request in the editor authenticates; null for no auth.
  Auth? _auth;

  /// Transport options for the request in the editor; null for the defaults.
  RequestSettings? _settings;

  /// Bumped whenever the editor loads a different request, so the auth form
  /// rebuilds from that request instead of keeping what was typed before.
  int _generation = 0;

  /// Whether the docked sidebar is hidden to give the editor more room.
  bool _sidebarCollapsed = false;

  WorkspaceStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _params.text = paramsTextFromUrl(_url.text);
    _url.addListener(_urlChanged);
    _params.addListener(_paramsChanged);
  }

  @override
  void dispose() {
    _url.dispose();
    _headers.dispose();
    _body.dispose();
    _urlEncoded.dispose();
    _binary.dispose();
    _params.dispose();
    super.dispose();
  }

  /// Typing in the URL bar updates the Params tab.
  void _urlChanged() {
    if (_syncing) return;
    final text = paramsTextFromUrl(_url.text);
    // Compared as pairs so that reformatting alone does not disturb the tab.
    if (urlWithParamsText('', text) == urlWithParamsText('', _params.text)) {
      return;
    }
    _syncing = true;
    _params.text = text;
    _syncing = false;
  }

  /// Editing the Params tab rewrites the URL's query string.
  void _paramsChanged() {
    if (_syncing) return;
    final url = urlWithParamsText(_url.text, _params.text);
    if (url == _url.text) return;
    _syncing = true;
    _url.text = url;
    _syncing = false;
  }

  /// Parses one `Name: value` per line; lines without a colon are skipped.
  List<Header> _parseHeaders() {
    final headers = <Header>[];
    for (final line in const LineSplitter().convert(_headers.text)) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      headers.add(
        Header(
          name: line.substring(0, i).trim(),
          value: line.substring(i + 1).trim(),
        ),
      );
    }
    return headers;
  }

  /// The request as typed, before variables are substituted.
  Request _request() {
    final body = switch (_bodyMode) {
      BodyMode.raw => _body.text,
      BodyMode.binary => _binary.text.trim(),
      _ => '',
    };
    final form = switch (_bodyMode) {
      BodyMode.formData => _formData,
      BodyMode.urlEncoded => [
        for (final line in _urlEncoded.text.split('\n'))
          if (parseKeyValueLine(line) case (final key, final value))
            FormField(key: key, value: value, file: false),
      ],
      _ => const <FormField>[],
    };
    // A body type with nothing in it is the same as no body.
    final empty = body.isEmpty && form.isEmpty;
    return Request(
      method: _method,
      url: _url.text.trim(),
      headers: _parseHeaders(),
      body: body.isEmpty ? null : body,
      bodyMode: empty ? null : _bodyMode,
      form: form,
      auth: _auth,
      settings: _settings,
    );
  }

  /// Shows a request's body in the editor for its type. Text bodies saved
  /// or imported as url-encoded strings open in the url-encoded table.
  void _loadBody(Request request) {
    final body = request.body ?? '';
    final encoded = request.headers.any(
      (h) =>
          h.name.toLowerCase() == 'content-type' &&
          h.value.toLowerCase().contains('x-www-form-urlencoded'),
    );
    var mode =
        request.bodyMode ?? (body.isEmpty ? BodyMode.none : BodyMode.raw);
    var fields = request.form;
    if (mode != BodyMode.formData &&
        fields.isEmpty &&
        encoded &&
        body.isNotEmpty) {
      mode = BodyMode.urlEncoded;
      String decode(String s) {
        try {
          return Uri.decodeQueryComponent(s);
        } catch (_) {
          return s;
        }
      }

      fields = [
        for (final pair in body.split('&'))
          if (pair.isNotEmpty)
            switch (pair.indexOf('=')) {
              < 0 => FormField(key: decode(pair), value: '', file: false),
              final i => FormField(
                key: decode(pair.substring(0, i)),
                value: decode(pair.substring(i + 1)),
                file: false,
              ),
            },
      ];
    }
    _bodyMode = mode;
    _body.text = mode == BodyMode.raw ? body : '';
    _binary.text = mode == BodyMode.binary ? body : '';
    _formData = mode == BodyMode.formData ? fields : const [];
    _urlEncoded.text = mode == BodyMode.urlEncoded
        ? [for (final f in fields) '${f.key}: ${f.value}'].join('\n')
        : '';
  }

  /// The raw-body type whose Content-Type the headers currently carry.
  String? _rawLanguage() {
    for (final header in _parseHeaders()) {
      if (header.name.toLowerCase() != 'content-type') continue;
      final value = header.value.toLowerCase();
      for (final entry in rawLanguages.entries) {
        if (value.startsWith(entry.value)) return entry.key;
      }
    }
    return null;
  }

  /// Sets the Content-Type header for a raw body, replacing any existing one.
  void _setRawLanguage(String name) {
    final lines = [
      for (final line in _headers.text.split('\n'))
        if (line.trim().isNotEmpty &&
            !line.trim().toLowerCase().startsWith('content-type:'))
          line,
      'Content-Type: ${rawLanguages[name]}',
    ];
    setState(() => _headers.text = lines.join('\n'));
  }

  void _open(RequestRef ref) {
    final request = _store.itemAt(ref)?.request;
    if (request == null) return;
    setState(() {
      _origin = ref;
      _method = request.method.toUpperCase();
      _url.text = request.url;
      _headers.text = [for (final h in request.headers) '${h.name}: ${h.value}']
          .join('\n');
      _loadBody(request);
      _auth = request.auth;
      _settings = request.settings;
      _generation++;
      _sent = null;
      _error = null;
    });
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState!.closeDrawer();
    }
  }

  /// Clears the editor for a request that is not saved anywhere yet.
  void _newRequest() {
    setState(() {
      _origin = null;
      _method = 'GET';
      _url.clear();
      _headers.clear();
      _body.clear();
      _bodyMode = BodyMode.none;
      _urlEncoded.clear();
      _formData = const [];
      _binary.clear();
      _auth = null;
      _settings = null;
      _generation++;
      _sent = null;
      _error = null;
    });
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState!.closeDrawer();
    }
  }

  Future<void> _send() async {
    final request = _request();
    if (request.url.isEmpty || _sending) return;
    // A leading variable usually holds the scheme already.
    final url = request.url.contains('://') || request.url.startsWith('{{')
        ? request.url
        : 'http://${request.url}';

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
        ),
        variables: _store.variablesFor(_origin?.collection),
        settings: _store.settings,
        cookies: _store.cookies,
      );
      // Keep whatever the server set, even if this page has gone away.
      _store.setCookies(sent.cookies);
      if (!mounted) return;
      setState(() => _sent = sent);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sent = null;
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _save() async {
    final request = _request();
    final origin = _origin;
    if (origin != null && _store.itemAt(origin)?.request != null) {
      _store.updateRequest(origin, request);
      showMessage(context, 'Saved');
      return;
    }
    final path = Uri.tryParse(request.url)?.path ?? '';
    final target = await showDialog<_SaveTarget>(
      context: context,
      builder: (_) => _SaveDialog(
        collections: [for (final c in _store.collections) c.name],
        suggestedName: '${request.method} ${path.isEmpty ? '/' : path}',
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
    setState(() => _origin = ref);
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
            onOpen: _open,
            onNewRequest: _newRequest,
            onRemoved: () => setState(() => _origin = null),
            onCollapse: docked ? toggle : null,
          );
          const width = _sidebarWidth + 1;
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
                  toggle,
              const SingleActivator(LogicalKeyboardKey.keyB, control: true):
                  toggle,
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

  Widget _main(
    BuildContext context, {
    required bool showMenu,
    required VoidCallback onMenu,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final request = _RequestEditor(
      params: _params,
      headers: _headers,
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
          onChanged: (fields) => _formData = fields,
        ),
        binary: _binary,
      ),
      cookies: CookiesTab(store: _store, currentUrl: () => _url.text),
      settings: RequestSettingsEditor(
        key: ValueKey(_generation),
        settings: _settings,
        appHttpMode: _store.settings.httpMode,
        onChanged: (settings) => _settings = settings,
      ),
      bulk: _bulk,
      onBulkChanged: (name, bulk) => setState(() {
        bulk ? _bulk.add(name) : _bulk.remove(name);
      }),
      auth: AuthEditor(
        key: ValueKey(_generation),
        auth: _auth,
        // No rebuild needed: the form already shows what was typed.
        onChanged: (auth) => _auth = auth,
      ),
    );
    final response = _ResponseView(
      sent: _sent,
      error: _error ?? _store.error,
      sending: _sending,
    );
    final active = _store.activeEnvironment;
    final openName = _origin == null ? null : _store.itemAt(_origin!)?.name;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              if (showMenu)
                IconButton(
                  key: const Key('show-sidebar'),
                  tooltip: 'Show collections',
                  icon: const Icon(Icons.menu),
                  onPressed: onMenu,
                ),
              DropdownButton<String>(
                key: const Key('method'),
                value: _method,
                underline: const SizedBox.shrink(),
                style: _mono.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
                items: [
                  // Imported requests may use a method outside the usual list.
                  for (final m in {..._methods, _method})
                    DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (m) => setState(() => _method = m ?? _method),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('url'),
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  controller: _url,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  style: _mono,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: '{{base_url}}/users',
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('send'),
                onPressed: _sending ? null : _send,
                child: const Text('Send'),
              ),
              IconButton(
                key: const Key('save'),
                tooltip: 'Save request',
                icon: const Icon(Icons.save_outlined),
                onPressed: _save,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
          child: Row(
            children: [
              Icon(Icons.layers_outlined, size: 18, color: scheme.outline),
              const SizedBox(width: 6),
              DropdownButton<String>(
                key: const Key('environment'),
                value: active ?? _noEnvironment,
                isDense: true,
                style: Theme.of(context).textTheme.bodyMedium,
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
                icon: const Icon(Icons.tune),
                onPressed: _manageEnvironments,
              ),
              const Spacer(),
              if (openName != null)
                Flexible(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      openName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Side by side when wide, stacked otherwise.
              if (constraints.maxWidth >= 900) {
                return Row(
                  children: [
                    Expanded(flex: 2, child: request),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 3, child: response),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(flex: 2, child: request),
                  const Divider(height: 1),
                  Expanded(flex: 3, child: response),
                ],
              );
            },
          ),
        ),
      ],
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
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            DropdownButton<int>(
              key: const Key('save-destination'),
              isExpanded: true,
              value: _destination,
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
            if (_destination == _SaveTarget.newCollection)
              TextField(
                key: const Key('save-collection'),
                controller: _newCollection,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Collection name'),
                onSubmitted: (_) => _submit(),
              ),
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

class _RequestEditor extends StatelessWidget {
  const _RequestEditor({
    required this.params,
    required this.headers,
    required this.body,
    required this.auth,
    required this.cookies,
    required this.settings,
    required this.bulk,
    required this.onBulkChanged,
  });

  final TextEditingController params;
  final TextEditingController headers;
  final Widget body;
  final Widget auth;
  final Widget cookies;
  final Widget settings;

  /// Names of the key-value tabs currently shown as text.
  final Set<String> bulk;
  final void Function(String name, bool bulk) onBulkChanged;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: Column(
        children: [
          const TabBar(
            labelPadding: EdgeInsets.symmetric(horizontal: 4),
            tabs: [
              Tab(key: Key('params-tab'), text: 'Params'),
              Tab(key: Key('headers-tab'), text: 'Headers'),
              Tab(text: 'Body'),
              Tab(key: Key('auth-tab'), text: 'Auth'),
              Tab(key: Key('cookies-tab'), text: 'Cookies'),
              Tab(key: Key('request-settings-tab'), text: 'Settings'),
            ],
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
                body,
                auth,
                cookies,
                settings,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResponseView extends StatelessWidget {
  const _ResponseView({
    required this.sent,
    required this.error,
    required this.sending,
  });

  final Sent? sent;
  final String? error;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final response = sent?.response;
    final unresolved = sent?.unresolved ?? const <String>[];

    if (sending) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          error!,
          key: const Key('error'),
          style: _mono.copyWith(color: scheme.error),
        ),
      );
    }
    if (response == null) {
      return Center(
        child: Text(
          'Send a request to see the response',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }

    final statusColor = response.status >= 400
        ? scheme.error
        : response.status >= 300
        ? scheme.tertiary
        : Colors.green.shade600;

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Wrap(
              spacing: 16,
              children: [
                Text(
                  '${response.status} ${response.statusText}',
                  key: const Key('status'),
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text('${response.elapsedMs} ms'),
                Text(_formatSize(response.sizeBytes)),
                Text(response.httpVersion),
                if (unresolved.isNotEmpty)
                  Text(
                    'Unresolved: ${unresolved.join(', ')}',
                    key: const Key('unresolved'),
                    style: TextStyle(color: scheme.error),
                  ),
              ],
            ),
          ),
          TabBar(
            tabs: [
              const Tab(text: 'Body'),
              Tab(text: 'Headers (${response.headers.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _Output(
                  key: const Key('responseBody'),
                  text: _prettyBody(response),
                ),
                _Output(
                  text: [
                    for (final h in response.headers) '${h.name}: ${h.value}',
                  ].join('\n'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Output extends StatelessWidget {
  const _Output({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        width: double.infinity,
        child: SelectableText(text, style: _mono),
      ),
    );
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Re-indents JSON bodies; anything else is shown as received.
String _prettyBody(Response response) {
  final isJson = response.headers.any(
    (h) =>
        h.name.toLowerCase() == 'content-type' &&
        h.value.toLowerCase().contains('json'),
  );
  if (!isJson) return response.body;
  try {
    return const JsonEncoder.withIndent('  ')
        .convert(jsonDecode(response.body));
  } catch (_) {
    return response.body;
  }
}
