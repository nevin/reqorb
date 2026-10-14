/// A page for reading and editing an OpenAPI or Swagger document: the text
/// on one side, and on the other the API it describes and what is wrong
/// with it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/line_view.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/shared/split_view.dart';
import 'package:reqorb/shared/text_dialog.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/spec/api_spec.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/transfer/export_actions.dart';
import 'package:reqorb/transfer/import_actions.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// Opens the spec page, empty, with ways to open a document. [onTry]
/// opens an operation tried there as a request.
Future<void> showSpecs(
  BuildContext context,
  WorkspaceStore store, {
  void Function(String name, Request request)? onTry,
}) {
  final engine = Engine.of(context);
  // Trying one operation after another reads the document once.
  String? importedText;
  ImportResult? imported;
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => SpecPage(
        onImport: (context, name, text) => runImport(
          context,
          store,
          () => engine.importText(text: text, nameHint: nameHintFor(name)),
        ),
        onTry: onTry == null
            ? null
            : (op, text, server) async {
                if (text != importedText) {
                  imported = await engine.importText(text: text, nameHint: '');
                  importedText = text;
                }
                final tried = requestFor(imported!, op, server: server);
                if (tried == null) return false;
                onTry(tried.name, tried.request);
                return true;
              },
      ),
    ),
  );
}

/// The request that importing a spec made for [op], with the collection's
/// variables put in, since it is tried outside the collection: the server,
/// which [server] replaces when given, and the examples of its path
/// parameters. Null when the import has no such request.
({String name, Request request})? requestFor(
  ImportResult result,
  SpecOperation op, {
  String? server,
}) {
  final collection = result.collections.firstOrNull;
  if (collection == null) return null;
  // As the importer writes it: `/pets/{id}` as `/pets/{{id}}`.
  final url =
      '{{baseUrl}}${op.path.replaceAll('{', '{{').replaceAll('}', '}}')}';
  Item? find(List<Item> items) {
    for (final item in items) {
      final request = item.request;
      if (request != null &&
          request.method == op.method &&
          request.url == url) {
        return item;
      }
      if (find(item.items) case final found?) return found;
    }
    return null;
  }

  final item = find(collection.items);
  final request = item?.request;
  if (item == null || request == null) return null;
  final values = {
    for (final variable in collection.variables) variable.key: variable.value,
    'baseUrl': ?server,
  };
  String fill(String text) => text.replaceAllMapped(
    RegExp(r'\{\{([^{}]+)\}\}'),
    (match) => values[match[1]] ?? match[0]!,
  );
  return (
    name: item.name,
    request: Request(
      method: request.method,
      url: fill(request.url),
      headers: [
        for (final header in request.headers)
          Header(name: header.name, value: fill(header.value)),
      ],
      body: request.body == null ? null : fill(request.body!),
      timeoutMs: request.timeoutMs,
      auth: request.auth,
      settings: request.settings,
      bodyMode: request.bodyMode,
      form: request.form,
      grpcMethod: request.grpcMethod,
      protoPath: request.protoPath,
      graphqlVariables: request.graphqlVariables,
      graphqlOperation: request.graphqlOperation,
      tests: request.tests,
      captures: request.captures,
      preScript: request.preScript,
      postScript: request.postScript,
    ),
  );
}

/// Fetches the document at [url]; tests replace this.
Future<String> Function(Uri url) specFetcher = _fetch;

Future<String> _fetch(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(url);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, application/yaml, text/yaml, */*',
    );
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw HttpException('the server answered ${response.statusCode}');
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

enum _View { edit, split, preview }

/// Why a long spec cannot be edited here, over the text that shows it.
class _ReadOnlyNote extends StatelessWidget {
  const _ReadOnlyNote({required this.size});

  /// How long the text is, in characters.
  final int size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final megabytes = (size / (1024 * 1024)).toStringAsFixed(1);
    return ColoredBox(
      key: const Key('spec-read-only'),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.lock_outline,
              size: 16,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Read-only: at $megabytes MB this spec is too large to '
                'edit here. Save it to edit it in a code editor.',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SpecPage extends StatefulWidget {
  const SpecPage({
    super.key,
    required this.onImport,
    this.onTry,
    this.name,
    this.text,
  });

  /// A document to open with; none to start from the choices.
  final String? name;
  final String? text;

  /// Imports the document as a collection.
  final Future<void> Function(BuildContext context, String name, String text)
  onImport;

  /// Opens [SpecOperation] as a request to try, made from the document's
  /// text, with [server] as where the API is when the document does not
  /// say in full. Answers whether it could; null to offer no trying.
  final Future<bool> Function(SpecOperation op, String text, String? server)?
  onTry;

  @override
  State<SpecPage> createState() => _SpecPageState();
}

class _SpecPageState extends State<SpecPage> {
  final _code = CodeController();

  /// What the document is called, such as its file name; null until one
  /// is open.
  String? _name;

  /// Where the document was opened from, when that was a web address.
  Uri? _source;

  /// The text as last opened or saved, to know whether it has changed.
  String _saved = '';
  ApiSpec? _spec;
  Timer? _reading;

  /// Counts reads, so that one finishing after a later one is dropped.
  int _reads = 0;

  /// Whether a long document is being read in the background.
  bool _readingApart = false;

  /// Chosen by the user; until then, by the width of the page.
  _View? _view;
  double _split = 0.5;

  @override
  void initState() {
    super.initState();
    if (widget.text case final text?) _load(widget.name ?? 'openapi', text);
  }

  @override
  void dispose() {
    _reading?.cancel();
    _code.dispose();
    super.dispose();
  }

  bool get _changed => _name != null && _code.text != _saved;

  bool get _json => looksLikeJson(_code.text);

  /// Whether the text is too long to edit here, and so is shown
  /// read-only.
  bool get _tooLong => _code.text.length > editLimit;

  void _load(String name, String text) {
    _reading?.cancel();
    setState(() {
      _name = name;
      _source = null;
      _saved = text;
      _code.text = text;
      // Another document's preview would mislead while this one is read.
      _spec = null;
      _read(text);
    });
  }

  /// Reads [text] into [_spec]: at once when it is short, and otherwise
  /// on another isolate, keeping what was shown until it is done.
  void _read(String text) {
    final read = ++_reads;
    if (text.length <= readInBackgroundOver) {
      _spec = readSpec(text);
      _readingApart = false;
      return;
    }
    _readingApart = true;
    readSpecApart(text).then((spec) {
      if (!mounted || read != _reads) return;
      setState(() {
        _spec = spec;
        _readingApart = false;
      });
    });
  }

  /// Reads the text again once typing pauses.
  void _edited(String _) {
    _reading?.cancel();
    _reading = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _read(_code.text));
    });
    // The title shows whether there are changes.
    setState(() {});
  }

  /// Whether to drop unsaved changes; true when there are none.
  Future<bool> _mayDiscard() async {
    if (!_changed) return true;
    final drop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard your changes?'),
        content: Text('$_name has changes that are not saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            key: const Key('spec-discard'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return drop ?? false;
  }

  Future<void> _openFile() async {
    if (!await _mayDiscard() || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await FilePicker.pickFile();
      if (file == null) return;
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      if (mounted) _load(file.name, text);
    } catch (e) {
      notify(messenger, 'Could not read the file: $e');
    }
  }

  Future<void> _openUrl() async {
    if (!await _mayDiscard() || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => const TextDialog(
        title: 'Open from URL',
        action: 'Open',
        fieldKey: Key('spec-url-field'),
        hint: 'https://petstore3.swagger.io/api/v3/openapi.json',
        helper: 'An OpenAPI or Swagger document, in JSON or YAML',
        lines: 1,
      ),
    );
    final address = typed?.trim() ?? '';
    if (address.isEmpty) return;
    final url = Uri.tryParse(
      address.contains('://') ? address : 'https://$address',
    );
    if (url == null || url.host.isEmpty) {
      notify(messenger, 'That is not a web address');
      return;
    }
    try {
      final text = await specFetcher(url);
      final last = url.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
      if (!mounted) return;
      _load(last ?? url.host, text);
      _source = url;
    } catch (e) {
      notify(messenger, 'Could not open $url: $e');
    }
  }

  Future<void> _paste() async {
    if (!await _mayDiscard() || !mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const TextDialog(
        title: 'Paste a spec',
        action: 'Open',
        fieldKey: Key('spec-paste-field'),
        hint: 'openapi: 3.0.3\ninfo:\n  title: …',
        lines: 10,
        url: false,
      ),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    _load(looksLikeJson(text) ? 'pasted.json' : 'pasted.yaml', text);
    // Pasted text has nowhere it is kept until it is saved.
    setState(() => _saved = '');
  }

  Future<void> _template() async {
    if (!await _mayDiscard() || !mounted) return;
    _load('openapi.yaml', specTemplate);
    setState(() => _saved = '');
  }

  String get _fileName {
    final name = _name ?? 'openapi';
    final extension = _json ? '.json' : '.yaml';
    final dot = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name) + extension;
  }

  Future<void> _save() async {
    final text = _code.text;
    await saveCodeFile(context, _fileName, text);
    if (mounted) setState(() => _saved = text);
  }

  /// Shows [line] in the editor, bringing the editor out if only the
  /// preview is showing.
  void _goToLine(int line) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (_view != _View.edit && !(_view != _View.preview && wide)) {
      setState(() => _view = wide ? _View.split : _View.edit);
    }
    // Once the editor is built, if it was not.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted) _code.goToLine(line);
      })
      ..scheduleFrame();
  }

  /// Where the API is, when the document gives only a path, such as
  /// `/api/v3`: that path from where the document was opened.
  String? get _server {
    final first = _spec?.servers.firstOrNull;
    final source = _source;
    if (first == null || source == null || first.contains('://')) return null;
    final server = source.resolve(first).toString();
    return server.endsWith('/')
        ? server.substring(0, server.length - 1)
        : server;
  }

  /// Opens [op] as a request, and says so.
  Future<void> _try(SpecOperation op) async {
    final onTry = widget.onTry;
    if (onTry == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (await onTry(op, _code.text, _server)) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('${op.method} ${op.path} is open in a new tab'),
              action: SnackBarAction(
                label: 'Go to it',
                onPressed: () async {
                  if (!mounted || !await _mayDiscard() || !mounted) return;
                  // Changes, if any, were dropped just now.
                  _saved = _code.text;
                  Navigator.pop(context);
                },
              ),
            ),
          );
      } else {
        notify(
          messenger,
          'Could not make a request for ${op.method} ${op.path}',
        );
      }
    } catch (e) {
      notify(messenger, 'Could not read the spec to try it: $e');
    }
  }

  /// Re-indents JSON, or writes YAML out as JSON.
  Future<void> _toJson() async {
    final spec = _spec;
    if (spec == null || !spec.readable) return;
    final text = _code.text;
    String convert() =>
        const JsonEncoder.withIndent('  ').convert(readTree(text));
    // A long one would stall the page for seconds.
    final json = text.length > readInBackgroundOver
        ? await Isolate.run(convert, debugName: 'toJson')
        : convert();
    // Unless it was edited meanwhile.
    if (!mounted || _code.text != text) return;
    _code.text = json;
    _edited(json);
  }

  @override
  Widget build(BuildContext context) {
    final name = _name;
    return PopScope(
      canPop: !_changed,
      onPopInvokedWithResult: (popped, _) async {
        if (popped || !await _mayDiscard() || !context.mounted) return;
        _saved = _code.text;
        Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            name == null ? 'API specs' : '${_changed ? '• ' : ''}$name',
            key: const Key('spec-title'),
          ),
          actions: [
            PopupMenuButton<VoidCallback>(
              key: const Key('spec-open'),
              tooltip: 'Open another spec',
              icon: const Icon(Icons.folder_open_outlined),
              onSelected: (action) => action(),
              itemBuilder: (_) => _openItems(),
            ),
            if (name != null) ...[
              IconButton(
                key: const Key('spec-save'),
                tooltip: 'Save as…',
                icon: const Icon(Icons.save_outlined),
                onPressed: _save,
              ),
              PopupMenuButton<VoidCallback>(
                key: const Key('spec-more'),
                tooltip: 'More',
                onSelected: (action) => action(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    key: const Key('spec-to-json'),
                    enabled: _spec?.readable ?? false,
                    value: _toJson,
                    child: Text(_json ? 'Format JSON' : 'Convert to JSON'),
                  ),
                  PopupMenuItem(
                    key: const Key('spec-copy'),
                    value: () async {
                      await Clipboard.setData(ClipboardData(text: _code.text));
                      if (context.mounted) showMessage(context, 'Spec copied');
                    },
                    child: const Text('Copy all'),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              FilledButton.tonalIcon(
                key: const Key('spec-import'),
                icon: const Icon(Icons.playlist_add, size: 18),
                label: const Text('Import as collection'),
                onPressed: () => widget.onImport(context, name, _code.text),
              ),
              const SizedBox(width: 12),
            ],
          ],
        ),
        body: name == null ? _start(context) : _body(context),
      ),
    );
  }

  List<PopupMenuEntry<VoidCallback>> _openItems() => [
    PopupMenuItem(
      key: const Key('spec-open-file'),
      value: _openFile,
      child: const Text('Open file…'),
    ),
    PopupMenuItem(
      key: const Key('spec-open-url'),
      value: _openUrl,
      child: const Text('Open from URL…'),
    ),
    PopupMenuItem(
      key: const Key('spec-open-paste'),
      value: _paste,
      child: const Text('Paste…'),
    ),
    PopupMenuItem(
      key: const Key('spec-open-template'),
      value: _template,
      child: const Text('New from a template'),
    ),
  ];

  /// Before a document is open: what the page is for, and ways to begin.
  Widget _start(BuildContext context) {
    final theme = Theme.of(context);
    Widget choice(Key key, IconData icon, String label, VoidCallback onTap) =>
        SizedBox(
          width: 260,
          child: OutlinedButton.icon(
            key: key,
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            icon: Icon(icon, size: 20),
            label: Text(label),
            onPressed: onTap,
          ),
        );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'Read and edit an API spec',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'OpenAPI 3 or Swagger 2, in JSON or YAML',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            choice(
              const Key('spec-start-file'),
              Icons.folder_open_outlined,
              'Open file…',
              _openFile,
            ),
            const SizedBox(height: 8),
            choice(
              const Key('spec-start-url'),
              Icons.link,
              'Open from URL…',
              _openUrl,
            ),
            const SizedBox(height: 8),
            choice(
              const Key('spec-start-paste'),
              Icons.content_paste,
              'Paste…',
              _paste,
            ),
            const SizedBox(height: 8),
            choice(
              const Key('spec-start-template'),
              Icons.note_add_outlined,
              'New from a template',
              _template,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final view = _view ?? (wide ? _View.split : _View.preview);
      final editor = _tooLong
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ReadOnlyNote(size: _code.text.length),
                Expanded(child: LineView(controller: _code)),
              ],
            )
          : CodeEditor(
              name: 'spec-editor',
              controller: _code,
              language: _json ? CodeLanguage.json : CodeLanguage.yaml,
              onChanged: _edited,
            );
      final preview = _Preview(
        spec: _spec,
        onLine: _goToLine,
        onTry: widget.onTry == null ? null : _try,
      );
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                SegmentedButton<_View>(
                  key: const Key('spec-view'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity(horizontal: -2, vertical: -2),
                  ),
                  segments: [
                    const ButtonSegment(
                      value: _View.edit,
                      label: Text('Edit', key: Key('spec-view-edit')),
                    ),
                    if (wide)
                      const ButtonSegment(
                        value: _View.split,
                        label: Text('Split', key: Key('spec-view-split')),
                      ),
                    const ButtonSegment(
                      value: _View.preview,
                      label: Text('Preview', key: Key('spec-view-preview')),
                    ),
                  ],
                  // A split chosen on a wide page shows the preview when
                  // the page narrows.
                  selected: {
                    view == _View.split && !wide ? _View.preview : view,
                  },
                  onSelectionChanged: (picked) =>
                      setState(() => _view = picked.first),
                ),
                const SizedBox(width: 12),
                // On a narrow page what kind of document it is gives way,
                // but not whether it has problems.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _Status(spec: _spec, reading: _readingApart),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: switch (view) {
              _View.edit => editor,
              _View.preview => preview,
              _View.split when !wide => preview,
              _View.split => SplitView(
                axis: Axis.horizontal,
                fraction: _split,
                onChanged: (fraction) => setState(() => _split = fraction),
                first: editor,
                second: preview,
              ),
            },
          ),
        ],
      );
    },
  );
}

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

/// What kind of document it is, and whether anything is wrong with it.
class _Status extends StatelessWidget {
  const _Status({required this.spec, required this.reading});

  final ApiSpec? spec;

  /// Whether a newer version of the text is being read.
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = this.spec;
    if (reading) {
      return Row(
        key: const Key('spec-reading'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            'Reading…',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      );
    }
    if (spec == null) return const SizedBox.shrink();
    final problems = spec.problems.length;
    final webhooks = spec.webhooks.length;
    final paths = spec.operations.length - webhooks;
    final ok = problems == 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spec.specVersion.isNotEmpty)
          Flexible(
            child: Text(
              [
                spec.specVersion,
                spec.format.toUpperCase(),
                // A document of webhooks alone need not say it has no
                // paths.
                if (paths > 0 || webhooks == 0) _count(paths, 'operation'),
                if (webhooks > 0) _count(webhooks, 'webhook'),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
        const SizedBox(width: 12),
        Icon(
          ok ? Icons.check_circle_outline : Icons.error_outline,
          size: 16,
          color: ok ? statusColor(200, scheme) : scheme.error,
        ),
        const SizedBox(width: 4),
        Text(
          ok
              ? 'No problems'
              : '$problems ${problems == 1 ? 'problem' : 'problems'}',
          key: const Key('spec-status'),
          style: TextStyle(
            fontSize: 13,
            color: ok ? statusColor(200, scheme) : scheme.error,
          ),
        ),
      ],
    );
  }
}

/// The API as documentation: its details, its problems, and its
/// operations by tag.
class _Preview extends StatefulWidget {
  const _Preview({required this.spec, required this.onLine, this.onTry});

  final ApiSpec? spec;

  /// Shows a line of the text in the editor.
  final ValueChanged<int> onLine;

  /// Opens an operation as a request; null to offer no trying.
  final ValueChanged<SpecOperation>? onTry;

  @override
  State<_Preview> createState() => _PreviewState();
}

/// One entry in the preview's list: what builds it, and for a card, its
/// id there.
typedef _Item = ({String? id, Widget Function() build});

class _PreviewState extends State<_Preview> {
  final _filter = TextEditingController();
  final _scroll = ScrollController();

  /// Each card's key, to find it once it is built, and what opens it,
  /// which keeps it open while it is scrolled away and built again. By
  /// the card's id: `op:GET /pets`, `hook:newPet`, `schema:Pet`.
  final _keys = <String, GlobalKey>{};
  final _openers = <String, ExpansibleController>{};

  /// The ids of the entries in the list as last built, in order.
  List<String?> _ids = const [];

  /// Counts the schemas shown, so that one shown later takes over.
  int _shows = 0;
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    _filter.dispose();
    _scroll.dispose();
    for (final opener in _openers.values) {
      opener.dispose();
    }
    super.dispose();
  }

  GlobalKey _key(String id) => _keys.putIfAbsent(id, GlobalKey.new);
  ExpansibleController _opener(String id) =>
      _openers.putIfAbsent(id, ExpansibleController.new);

  /// Opens the schema called [name] and scrolls to it.
  void _show(String name) {
    final id = 'schema:$name';
    // A filter could be hiding it.
    if (_filter.text.isNotEmpty) setState(_filter.clear);
    // Opened even before it is built, it is built open.
    _opener(id).expand();
    final show = ++_shows;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _reveal(id, show))
      ..scheduleFrame();
  }

  /// Scrolls until the card [id] is built, then brings it into view.
  Future<void> _reveal(String id, int show) async {
    final index = _ids.indexOf(id);
    var guessed = false;
    for (var step = 0; index >= 0 && step < 50; step++) {
      if (!mounted || show != _shows || !_scroll.hasClients) return;
      if (_key(id).currentContext case final card? when card.mounted) {
        _bringIntoView(card);
        // And again once it has opened out and there is room below it.
        _settle?.cancel();
        _settle = Timer(const Duration(milliseconds: 300), () {
          final card = _key(id).currentContext;
          if (mounted && show == _shows && card != null) _bringIntoView(card);
        });
        return;
      }
      final position = _scroll.position;
      final double to;
      if (!guessed) {
        // The list reckons its length from the entries built so far, so
        // the same share of that length lands near.
        guessed = true;
        to =
            (position.maxScrollExtent + position.viewportDimension) *
            index /
            _ids.length;
      } else {
        final first = _ids.indexWhere(
          (id) => id != null && _keys[id]?.currentContext != null,
        );
        final back = first >= 0 && index < first;
        to = position.pixels + (back ? -1 : 1) * position.viewportDimension;
      }
      position.jumpTo(
        to.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _bringIntoView(BuildContext card) => Scrollable.ensureVisible(
    card,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
    alignment: 0.05,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = widget.spec;
    if (spec == null) return const SizedBox.shrink();
    final query = _filter.text.trim().toLowerCase();
    bool matches(SpecOperation op) =>
        query.isEmpty ||
        '${op.method} ${op.path} ${op.summary} ${op.operationId}'
            .toLowerCase()
            .contains(query);
    final groups = {
      for (final MapEntry(:key, :value) in spec.byTag.entries)
        if (value.where(matches).isNotEmpty) key: value.where(matches).toList(),
    };
    final webhooks = spec.webhooks.where(matches).toList();
    final schemas = [
      for (final schema in spec.schemas)
        if (query.isEmpty || schema.name.toLowerCase().contains(query)) schema,
    ];
    final names = {for (final schema in spec.schemas) schema.name};
    final links = (names: names, open: _show);
    Widget heading(String text, Key key, [String? note]) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, key: key, style: theme.textTheme.titleSmall),
          if (note != null)
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );

    // A list built as it is scrolled, as a spec can have thousands of
    // operations and schemas.
    final items = <_Item>[];
    void add(Widget Function() build, [String? id]) =>
        items.add((id: id, build: build));
    void addOperation(SpecOperation op, String id) => add(
      () => _Operation(
        key: _key(id),
        spec: spec,
        op: op,
        opener: _opener(id),
        links: links,
        // A webhook is a request the API sends, not one to send it.
        onTry: op.webhook ? null : widget.onTry,
      ),
      id,
    );

    if (spec.readable) {
      add(
        () => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    spec.title.isEmpty ? 'Untitled API' : spec.title,
                    key: const Key('spec-api-title'),
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (spec.version.isNotEmpty) _Chip(spec.version),
                  if (spec.specVersion.isNotEmpty) _Chip(spec.specVersion),
                ],
              ),
              if (spec.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(spec.description),
              ],
              if (spec.servers.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final server in spec.servers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      server,
                      style: mono.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    }
    if (spec.problems.isNotEmpty) {
      add(
        () => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _Problems(problems: spec.problems, onLine: widget.onLine),
        ),
      );
    }
    if (spec.operations.isNotEmpty || spec.schemas.isNotEmpty) {
      add(
        () => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            key: const Key('spec-filter'),
            controller: _filter,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: spec.schemas.isEmpty
                  ? 'Filter operations'
                  : 'Filter operations and schemas',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      );
      for (final MapEntry(key: tag, value: operations) in groups.entries) {
        add(
          () => Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text(tag, style: theme.textTheme.titleSmall),
          ),
        );
        for (final op in operations) {
          addOperation(op, 'op:${op.method} ${op.path}');
        }
      }
      if (webhooks.isNotEmpty) {
        add(
          () => heading(
            'Webhooks',
            const Key('spec-webhooks'),
            'Requests the API sends to you',
          ),
        );
        for (final op in webhooks) {
          addOperation(op, 'hook:${op.method} ${op.path}');
        }
      }
      if (schemas.isNotEmpty) {
        add(
          () => heading(
            'Schemas (${spec.schemas.length})',
            const Key('spec-schemas'),
            'What the requests and responses carry',
          ),
        );
        for (final schema in schemas) {
          final id = 'schema:${schema.name}';
          add(
            () => _Schema(
              key: _key(id),
              schema: schema,
              opener: _opener(id),
              links: links,
            ),
            id,
          );
        }
      }
      if (groups.isEmpty && webhooks.isEmpty && schemas.isEmpty) {
        add(
          () => Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Nothing matches',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        );
      }
    }
    if (spec.security.isNotEmpty) {
      add(() => heading('Security', const Key('spec-security')));
      for (final security in spec.security) {
        add(
          () => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 160, child: Text(security.name, style: mono)),
                Expanded(
                  child: Text(
                    [
                      security.summary,
                      if (security.description.isNotEmpty) security.description,
                    ].join(' — '),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }
    _ids = [for (final item in items) item.id];

    return SelectionArea(
      child: ListView.builder(
        key: const Key('spec-preview'),
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (_, index) => items[index].build(),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

class _Problems extends StatelessWidget {
  const _Problems({required this.problems, required this.onLine});

  final List<SpecProblem> problems;

  /// Shows a line of the text, for a problem that knows its line.
  final ValueChanged<int> onLine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const Key('spec-problems'),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, problem) in problems.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 16, color: scheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        problem.message,
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                    if (problem.line case final line?)
                      InkWell(
                        key: Key('spec-problem-line-$i'),
                        onTap: () => onLine(line),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            'Line $line',
                            style: TextStyle(
                              color: scheme.onErrorContainer,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One operation, folded to a line until opened.
/// The schemas there are, and how to show one: what a type that names a
/// schema links to.
typedef _Links = ({Set<String> names, ValueChanged<String> open});

/// A type, such as `array of Pet`, with each schema it names a link to it.
class _TypeText extends StatelessWidget {
  const _TypeText(this.type, this.links);

  final String type;
  final _Links links;

  static final _word = RegExp(r'[A-Za-z0-9_.\-]+');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = mono.copyWith(color: scheme.primary);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final match in _word.allMatches(type)) {
      final name = match[0]!;
      if (!links.names.contains(name)) continue;
      if (match.start > at) {
        spans.add(TextSpan(text: type.substring(at, match.start)));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: Key('spec-link-$name'),
              onTap: () => links.open(name),
              child: Text(
                name,
                style: style.copyWith(
                  decoration: TextDecoration.underline,
                  decorationColor: scheme.primary.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ),
      );
      at = match.end;
    }
    if (at < type.length) spans.add(TextSpan(text: type.substring(at)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

/// A named schema, folded to a line until opened.
class _Schema extends StatelessWidget {
  const _Schema({
    super.key,
    required this.schema,
    required this.opener,
    required this.links,
  });

  final SpecSchema schema;
  final ExpansibleController opener;
  final _Links links;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: Key('spec-schema-${schema.name}'),
        controller: opener,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Row(
          children: [
            Text(
              schema.name,
              style: mono.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 12),
            if (schema.type.isNotEmpty) _TypeText(schema.type, links),
            if (schema.description.isNotEmpty) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  schema.description,
                  style: muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
        children: [
          if (schema.description.isNotEmpty) Text(schema.description),
          if (schema.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(schema.notes.join(' · '), style: small),
            ),
          if (schema.fields.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final field in schema.fields)
              Padding(
                padding: EdgeInsets.fromLTRB(field.depth * 20.0, 3, 0, 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 180 - field.depth * 20.0,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            if (field.depth > 0)
                              TextSpan(
                                text: '└ ',
                                style: TextStyle(color: scheme.outline),
                              ),
                            TextSpan(text: field.name),
                            if (field.required)
                              TextSpan(
                                text: ' *',
                                style: TextStyle(color: scheme.error),
                              ),
                          ],
                        ),
                        style: mono,
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: _TypeText(
                          field.type.isEmpty ? 'any' : field.type,
                          links,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (field.description.isNotEmpty)
                            Text(field.description, style: muted),
                          if (field.notes.isNotEmpty)
                            Text(field.notes.join(' · '), style: small),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (schema.fields.isEmpty && schema.notes.isEmpty)
            Text('No fields', style: muted),
        ],
      ),
    );
  }
}

class _Operation extends StatelessWidget {
  const _Operation({
    super.key,
    required this.spec,
    required this.op,
    required this.opener,
    required this.links,
    this.onTry,
  });

  /// Opens [op] as a request; null to offer no trying.
  final ValueChanged<SpecOperation>? onTry;

  /// The spec [op] is in, which its examples are made from.
  final ApiSpec spec;
  final SpecOperation op;
  final ExpansibleController opener;
  final _Links links;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final small = theme.textTheme.labelLarge;
    Widget section(String title, List<Widget> rows) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: small),
          const SizedBox(height: 4),
          ...rows,
        ],
      ),
    );
    Widget row(String left, String middle, String right, {Color? color}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 160,
                child: Text(left, style: mono.copyWith(color: color)),
              ),
              SizedBox(
                width: 220,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _TypeText(middle, links),
                ),
              ),
              Expanded(child: Text(right, style: muted)),
            ],
          ),
        );

    // Made only once the card is open, as only then are its children
    // built.
    Map<String, String> examples(
      Iterable<(String, SpecContent)> labelled, {
      required bool request,
    }) {
      final out = <String, String>{};
      for (final (label, content) in labelled) {
        if (out.containsKey(label)) continue;
        if (exampleOf(spec, content, request: request) case final json?) {
          out[label] = json;
        }
      }
      return out;
    }

    final name = '${op.method}-${op.path}';

    return Card(
      key: Key('spec-op-$name'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        controller: opener,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                op.method,
                style: mono.copyWith(
                  fontWeight: FontWeight.w700,
                  color: methodColor(op.method, theme.brightness),
                ),
              ),
            ),
            Flexible(
              child: Text(
                op.path,
                style: mono.copyWith(
                  decoration: op.deprecated ? TextDecoration.lineThrough : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (op.summary.isNotEmpty) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  op.summary,
                  style: muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
        children: [
          if (onTry case final onTry?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.tonalIcon(
                key: Key('spec-try-$name'),
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Try it'),
                onPressed: () => onTry(op),
              ),
            ),
          if (op.deprecated)
            Text('Deprecated', style: TextStyle(color: scheme.error)),
          if (op.description.isNotEmpty) Text(op.description),
          if (op.operationId.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('operationId: ${op.operationId}', style: muted),
            ),
          if (op.parameters.isNotEmpty)
            section('Parameters', [
              for (final p in op.parameters)
                row(
                  '${p.name}${p.required ? ' *' : ''}',
                  '${p.location} · ${p.type.isEmpty ? 'any' : p.type}',
                  p.description,
                ),
            ]),
          if (op.body.isNotEmpty)
            section('Request body', [
              for (final c in op.body) row(c.type, c.schema, ''),
              _Example(
                key: Key('spec-example-body-$name'),
                examples: examples([
                  for (final c in op.body) (c.type, c),
                ], request: true),
              ),
            ]),
          if (op.responses.isNotEmpty)
            section('Responses', [
              for (final r in op.responses)
                row(
                  r.status,
                  r.content.map((c) => c.schema).toSet().join(', '),
                  r.description,
                  // `default` and ranges such as `4XX` are no one status.
                  color: switch (int.tryParse(r.status)) {
                    final status? => statusColor(status, scheme),
                    null => null,
                  },
                ),
              _Example(
                key: Key('spec-example-responses-$name'),
                // One for each status: the first content type that has one.
                examples: {
                  for (final r in op.responses)
                    ...examples([
                      for (final c in r.content) (r.status, c),
                    ], request: false),
                },
              ),
            ]),
        ],
      ),
    );
  }
}

/// Examples of a body, with a chip for each when there are several, as
/// for each status of a response.
class _Example extends StatefulWidget {
  const _Example({super.key, required this.examples});

  /// Each example's JSON, by what it is for, such as `200`.
  final Map<String, String> examples;

  @override
  State<_Example> createState() => _ExampleState();
}

class _ExampleState extends State<_Example> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final examples = widget.examples;
    if (examples.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // A success first, as that is what one usually wants to see.
    final first = examples.keys.firstWhere(
      (label) => label.startsWith('2'),
      orElse: () => examples.keys.first,
    );
    final picked = examples.containsKey(_picked) ? _picked! : first;
    final json = examples[picked]!;
    final lines = '\n'.allMatches(json).length + 1;
    final key = (widget.key as ValueKey<String>?)?.value ?? 'spec-example';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Example',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(width: 8),
              if (examples.length > 1)
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final label in examples.keys)
                        ChoiceChip(
                          key: Key('$key-$label'),
                          label: Text(label, style: mono),
                          visualDensity: VisualDensity.compact,
                          selected: label == picked,
                          onSelected: (_) => setState(() => _picked = label),
                        ),
                    ],
                  ),
                )
              else
                const Spacer(),
              IconButton(
                key: Key('$key-copy'),
                tooltip: 'Copy example',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: json));
                  if (context.mounted) showMessage(context, 'Example copied');
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                // Its own height, so that one swipe scrolls the page
                // rather than the example, up to about 20 lines; past that
                // it scrolls.
                height: (lines * 19.0 + 28).clamp(60, 420),
                child: CodeView(
                  key: ValueKey(picked),
                  name: '$key-code',
                  text: json,
                  language: CodeLanguage.json,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
