/// Asks what to call a new request and where to keep it.
library;

import 'package:flutter/material.dart';

/// Where the save dialog says a new request should go.
class SaveTarget {
  const SaveTarget(this.name, this.destination, this.newCollectionName);

  /// Save on its own, outside any collection.
  static const standalone = -2;

  /// Create a collection named [newCollectionName] and save into it.
  static const newCollection = -1;

  final String name;

  /// Index of an existing collection, or one of the constants above.
  final int destination;
  final String newCollectionName;
}

class SaveDialog extends StatefulWidget {
  const SaveDialog({
    super.key,
    required this.collections,
    required this.suggestedName,
  });

  final List<String> collections;
  final String suggestedName;

  @override
  State<SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<SaveDialog> {
  late final _name = TextEditingController(text: widget.suggestedName);
  final _newCollection = TextEditingController();
  int _destination = SaveTarget.standalone;

  @override
  void dispose() {
    _name.dispose();
    _newCollection.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final newName = _newCollection.text.trim();
    final needsName = _destination == SaveTarget.newCollection;
    if (name.isEmpty || (needsName && newName.isEmpty)) return;
    Navigator.pop(context, SaveTarget(name, _destination, newName));
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
                  value: SaveTarget.standalone,
                  child: Text('No collection'),
                ),
                for (var i = 0; i < widget.collections.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(widget.collections[i]),
                  ),
                const DropdownMenuItem(
                  value: SaveTarget.newCollection,
                  child: Text('New collection…'),
                ),
              ],
              onChanged: (i) =>
                  setState(() => _destination = i ?? _destination),
            ),
            if (_destination == SaveTarget.newCollection) ...[
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
