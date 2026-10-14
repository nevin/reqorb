/// A page for reading and editing an OpenAPI or Swagger document: the text
/// on one side, and on the other the API it describes and what is wrong
/// with it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/shared/split_view.dart';
import 'package:reqorb/shared/text_dialog.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/spec/api_spec.dart';
import 'package:reqorb/transfer/export_actions.dart';
import 'package:reqorb/transfer/import_actions.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// Opens the spec page, empty, with ways to open a document.
Future<void> showSpecs(BuildContext context, WorkspaceStore store) {
  final engine = Engine.of(context);
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => SpecPage(
        onImport: (context, name, text) => runImport(
          context,
          store,
          () => engine.importText(text: text, nameHint: nameHintFor(name)),
        ),
      ),
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

class SpecPage extends StatefulWidget {
  const SpecPage({super.key, required this.onImport, this.name, this.text});

  /// A document to open with; none to start from the choices.
  final String? name;
  final String? text;

  /// Imports the document as a collection.
  final Future<void> Function(BuildContext context, String name, String text)
  onImport;

  @override
  State<SpecPage> createState() => _SpecPageState();
}

class _SpecPageState extends State<SpecPage> {
  final _code = CodeController();

  /// What the document is called, such as its file name; null until one
  /// is open.
  String? _name;

  /// The text as last opened or saved, to know whether it has changed.
  String _saved = '';
  ApiSpec? _spec;
  Timer? _reading;

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

  void _load(String name, String text) {
    _reading?.cancel();
    setState(() {
      _name = name;
      _saved = text;
      _code.text = text;
      _spec = readSpec(text);
    });
  }

  /// Reads the text again once typing pauses.
  void _edited(String _) {
    _reading?.cancel();
    _reading = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _spec = readSpec(_code.text));
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
      if (mounted) _load(last ?? url.host, text);
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

  /// Re-indents JSON, or writes YAML out as JSON.
  void _toJson() {
    final spec = _spec;
    if (spec == null || !spec.readable) return;
    final value = readTree(_code.text);
    _code.text = const JsonEncoder.withIndent('  ').convert(value);
    _edited(_code.text);
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
      final editor = CodeEditor(
        name: 'spec-editor',
        controller: _code,
        language: _json ? CodeLanguage.json : CodeLanguage.yaml,
        onChanged: _edited,
      );
      final preview = _Preview(spec: _spec);
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
                const Spacer(),
                _Status(spec: _spec),
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
  const _Status({required this.spec});

  final ApiSpec? spec;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = this.spec;
    if (spec == null) return const SizedBox.shrink();
    final problems = spec.problems.length;
    final webhooks = spec.webhooks.length;
    final paths = spec.operations.length - webhooks;
    final ok = problems == 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spec.specVersion.isNotEmpty)
          Text(
            [
              spec.specVersion,
              spec.format.toUpperCase(),
              // A document of webhooks alone need not say it has no paths.
              if (paths > 0 || webhooks == 0) _count(paths, 'operation'),
              if (webhooks > 0) _count(webhooks, 'webhook'),
            ].join(' · '),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
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
  const _Preview({required this.spec});

  final ApiSpec? spec;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

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

    return SelectionArea(
      child: ListView(
        key: const Key('spec-preview'),
        padding: const EdgeInsets.all(16),
        children: [
          if (spec.readable) ...[
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
            const SizedBox(height: 12),
          ],
          if (spec.problems.isNotEmpty) ...[
            _Problems(problems: spec.problems),
            const SizedBox(height: 12),
          ],
          if (spec.operations.isNotEmpty) ...[
            TextField(
              key: const Key('spec-filter'),
              controller: _filter,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Filter operations',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            for (final MapEntry(key: tag, value: operations)
                in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: Text(tag, style: theme.textTheme.titleSmall),
              ),
              for (final op in operations) _Operation(op: op),
            ],
            if (webhooks.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
                child: Text(
                  'Webhooks',
                  key: const Key('spec-webhooks'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                child: Text(
                  'Requests the API sends to you',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final op in webhooks) _Operation(op: op),
            ],
            if (groups.isEmpty && webhooks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No operation matches',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ],
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
  const _Problems({required this.problems});

  final List<SpecProblem> problems;

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
            for (final problem in problems)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 16, color: scheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        problem.line == null
                            ? problem.message
                            : '${problem.message}  (line ${problem.line})',
                        style: TextStyle(color: scheme.onErrorContainer),
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
class _Operation extends StatelessWidget {
  const _Operation({required this.op});

  final SpecOperation op;

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
                  child: Text(
                    middle,
                    style: mono.copyWith(color: scheme.primary),
                  ),
                ),
              ),
              Expanded(child: Text(right, style: muted)),
            ],
          ),
        );

    return Card(
      key: Key('spec-op-${op.method}-${op.path}'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
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
            ]),
        ],
      ),
    );
  }
}
