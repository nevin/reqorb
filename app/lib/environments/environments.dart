import 'package:flutter/material.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/code_controller.dart';

import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/transfer/import_actions.dart';
import 'package:reqorb/transfer/export_actions.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// `KEY=value` per line. A leading `#` marks a disabled variable, and the
/// word `secret` before the name one that holds a credential.
String variablesToText(List<Variable> variables) => [
  for (final v in variables)
    '${v.enabled ? '' : '# '}${v.secret ? 'secret ' : ''}${v.key}=${v.value}',
].join('\n');

List<Variable> textToVariables(String text) {
  final variables = <Variable>[];
  for (var line in text.split('\n')) {
    line = line.trim();
    final enabled = !line.startsWith('#');
    if (!enabled) line = line.substring(1).trim();
    final secret = line.startsWith('secret ');
    if (secret) line = line.substring(7).trim();
    final i = line.indexOf('=');
    if (i <= 0) continue;
    variables.add(
      Variable(
        key: line.substring(0, i).trim(),
        value: line.substring(i + 1).trim(),
        enabled: enabled,
        secret: secret,
      ),
    );
  }
  return variables;
}

/// Create, edit, import and export environments.
class EnvironmentsPage extends StatefulWidget {
  const EnvironmentsPage({super.key, required this.store});

  final WorkspaceStore store;

  @override
  State<EnvironmentsPage> createState() => _EnvironmentsPageState();
}

class _EnvironmentsPageState extends State<EnvironmentsPage> {
  final _name = TextEditingController();
  final _variables = CodeController();

  /// Set while an environment is being put into the fields, which is not
  /// an edit of it.
  bool _showing = false;
  int _index = 0;
  bool _nameTaken = false;

  WorkspaceStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    final active = _store.environments.indexWhere(
      (e) => e.name == _store.activeEnvironment,
    );
    _select(active < 0 ? 0 : active);
  }

  @override
  void dispose() {
    _name.dispose();
    _variables.dispose();
    super.dispose();
  }

  /// Shows the environment at [index] in the editor.
  void _select(int index) {
    _index = index;
    _nameTaken = false;
    if (index < _store.environments.length) {
      final environment = _store.environments[index];
      _showing = true;
      _name.text = environment.name;
      _variables.text = variablesToText(environment.variables);
      _showing = false;
    }
  }

  void _edited() {
    if (_showing) return;
    final name = _name.text.trim();
    final current = _store.environments[_index];
    final nameOk = _store.canRename(_index, name);
    setState(() => _nameTaken = !nameOk);
    _store.updateEnvironment(
      _index,
      Environment(
        name: nameOk ? name : current.name,
        variables: textToVariables(_variables.text),
        folder: current.folder,
      ),
    );
  }

  Future<void> _import() async {
    final before = _store.environments.length;
    await importFromFile(context, _store);
    if (mounted && _store.environments.length > before) {
      setState(() => _select(before));
    }
  }

  @override
  Widget build(BuildContext context) {
    final environments = _store.environments;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Environments'),
        actions: [
          IconButton(
            tooltip: 'Import environment',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _import,
          ),
          IconButton(
            key: const Key('env-add'),
            tooltip: 'New environment',
            icon: const Icon(Icons.add),
            onPressed: () => setState(() => _select(_store.addEnvironment())),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: environments.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No environments yet. Add one, or import a Postman '
                  'environment or a .env file.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // A list beside the editor when there is room for both.
                final wide = constraints.maxWidth >= 640;
                final editor = _editor(context, environments, picker: !wide);
                if (!wide) return editor;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 240, child: _list(context, environments)),
                    const VerticalDivider(width: 1),
                    Expanded(child: editor),
                  ],
                );
              },
            ),
    );
  }

  void _delete() {
    final index = _index;
    final removed = _store.environments[index];
    final active = _store.activeEnvironment == removed.name;
    _store.removeEnvironment(index);
    setState(() => _select(0));
    showUndo(context, 'Deleted environment "${removed.name}"', () {
      _store.insertEnvironment(index, removed, active: active);
      if (mounted) setState(() => _select(index));
    });
  }

  /// Every environment, with the one in use marked.
  Widget _list(BuildContext context, List<Environment> environments) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (var i = 0; i < environments.length; i++)
            ListTile(
              key: Key('env-item-$i'),
              dense: true,
              selected: i == _index,
              selectedTileColor: scheme.secondaryContainer,
              title: Text(
                environments[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${environments[i].variables.length} '
                '${environments[i].variables.length == 1 ? 'variable' : 'variables'}',
              ),
              trailing: environments[i].name == _store.activeEnvironment
                  ? Tooltip(
                      message: 'In use',
                      child: Icon(
                        Icons.check_circle,
                        size: 18,
                        color: scheme.primary,
                      ),
                    )
                  : null,
              onTap: () => setState(() => _select(i)),
            ),
        ],
      ),
    );
  }

  /// Where the environment is kept: in the workspace, or beside one of the
  /// collections kept in a folder, to be shared with it.
  List<Widget> _keptIn(BuildContext context, Environment current) {
    final linked = [
      for (final (i, c) in _store.collections.indexed)
        if (c.link != null) (i, c),
    ];
    if (linked.isEmpty && current.folder == null) return const [];
    final known = linked.any((l) => l.$2.link!.path == current.folder);
    return [
      const SizedBox(height: 12),
      // A field of its own for each environment and place, as a form field
      // keeps the value it started with.
      KeyedSubtree(
        key: ValueKey((_index, current.folder)),
        child: DropdownButtonFormField<String?>(
          key: const Key('env-kept-in'),
          initialValue: current.folder,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Kept in',
            helperText:
                'Kept in a collection’s folder, it is shared with the '
                'collection, credentials left out.',
          ),
          items: [
            const DropdownMenuItem(value: null, child: Text('This workspace')),
            for (final (_, c) in linked)
              DropdownMenuItem(
                value: c.link!.path,
                child: Text(
                  'The folder of ${c.name}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (current.folder != null && !known)
              DropdownMenuItem(
                value: current.folder,
                child: const Text('A folder no longer open'),
              ),
          ],
          onChanged: (folder) => setState(() {
            final at = linked.where((l) => l.$2.link!.path == folder);
            _store.keepEnvironmentWith(_index, at.firstOrNull?.$1);
          }),
        ),
      ),
    ];
  }

  Widget _editor(
    BuildContext context,
    List<Environment> environments, {
    required bool picker,
  }) {
    final current = environments[_index];
    final active = _store.activeEnvironment == current.name;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (picker)
                    Expanded(
                      child: DropdownButton<int>(
                        key: const Key('env-edit-select'),
                        isExpanded: true,
                        value: _index,
                        items: [
                          for (var i = 0; i < environments.length; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(environments[i].name),
                            ),
                        ],
                        onChanged: (i) => setState(() => _select(i ?? _index)),
                      ),
                    )
                  else
                    const Spacer(),
                  // Saves a trip back to the main screen to switch.
                  active
                      ? OutlinedButton.icon(
                          key: const Key('env-use'),
                          onPressed: () =>
                              setState(() => _store.setActiveEnvironment(null)),
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text('In use'),
                        )
                      : FilledButton.tonal(
                          key: const Key('env-use'),
                          onPressed: () => setState(
                            () => _store.setActiveEnvironment(current.name),
                          ),
                          child: const Text('Use'),
                        ),
                  PopupMenuButton<VoidCallback>(
                    tooltip: 'Environment actions',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (action) => action(),
                    itemBuilder: (_) => [
                      for (final (label, format) in const [
                        ('Export as reqorb JSON…', ExportFormat.reqorb),
                        ('Export as Postman…', ExportFormat.postman),
                        ('Export as .env…', ExportFormat.dotenv),
                      ])
                        PopupMenuItem(
                          value: () => exportEnvironmentFile(
                            context,
                            environments[_index],
                            format,
                          ),
                          child: Text(label),
                        ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        key: const Key('env-delete'),
                        value: _delete,
                        child: const Text('Delete environment'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('env-name'),
                controller: _name,
                decoration: InputDecoration(
                  isDense: false,
                  labelText: 'Name',
                  errorText: _nameTaken
                      ? 'Use a name no other environment has'
                      : null,
                ),
                onChanged: (_) => _edited(),
              ),
              ..._keptIn(context, current),
              const SizedBox(height: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Variables',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) => CodeBox(
                          height: box.maxHeight,
                          child: CodeEditor(
                            name: 'env-variables',
                            controller: _variables,
                            language: CodeLanguage.pairs,
                            hint:
                                'base_url=https://api.example.com\n'
                                'secret session=abc123',
                            hintLines: 2,
                            onChanged: (_) => _edited(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'One KEY=value per line. Start a line with # to '
                      'disable it, or with the word secret to keep its '
                      'value encrypted on disk and out of redacted '
                      'exports. Use {{KEY}} in a request.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
