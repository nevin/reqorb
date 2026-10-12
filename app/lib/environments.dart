import 'package:flutter/material.dart';

import 'actions.dart';
import 'src/rust/api/core.dart';
import 'workspace_store.dart';

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
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
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
                              onChanged: (i) =>
                                  setState(() => _select(i ?? _index)),
                            ),
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
                                value: () {
                                  _store.removeEnvironment(_index);
                                  setState(() => _select(0));
                                },
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
                          border: const OutlineInputBorder(),
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
                          style: const TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 13,
                            height: 1.4,
                          ),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
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
            ),
    );
  }
}
