import 'package:flutter/material.dart';

import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/transfer/import_actions.dart';
import 'package:reqorb/transfer/export_actions.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// `KEY=value` per line; a leading `#` marks a disabled variable.
String variablesToText(List<Variable> variables) =>
    [for (final v in variables) '${v.enabled ? '' : '# '}${v.key}=${v.value}']
        .join('\n');

List<Variable> textToVariables(String text) {
  final variables = <Variable>[];
  for (var line in text.split('\n')) {
    line = line.trim();
    final enabled = !line.startsWith('#');
    if (!enabled) line = line.substring(1).trim();
    final i = line.indexOf('=');
    if (i <= 0) continue;
    variables.add(
      Variable(
        key: line.substring(0, i).trim(),
        value: line.substring(i + 1).trim(),
        enabled: enabled,
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
  final _variables = TextEditingController();
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
      _name.text = environment.name;
      _variables.text = variablesToText(environment.variables);
    }
  }

  void _edited() {
    final name = _name.text.trim();
    final current = _store.environments[_index];
    final nameOk = _store.canRename(_index, name);
    setState(() => _nameTaken = !nameOk);
    _store.updateEnvironment(
      _index,
      Environment(
        name: nameOk ? name : current.name,
        variables: textToVariables(_variables.text),
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
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  key: const Key('env-variables'),
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  controller: _variables,
                  maxLines: null,
                  expands: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textAlignVertical: TextAlignVertical.top,
                  style: mono,
                  decoration: const InputDecoration(
                    labelText: 'Variables',
                    alignLabelWithHint: true,
                    hintText: 'base_url=https://api.example.com\ntoken=abc123',
                    helperText:
                        'One KEY=value per line. Start a line with # '
                        'to disable it. Use {{KEY}} in a request.',
                  ),
                  onChanged: (_) => _edited(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
