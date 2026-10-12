import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/rust/api/core.dart';
import 'theme.dart';
import 'workspace_store.dart';

void showMessage(BuildContext context, String message) =>
    _notify(ScaffoldMessenger.of(context), message);

/// Reports something that was just removed and offers to put it back.
void showUndo(BuildContext context, String message, VoidCallback undo) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: 'Undo', onPressed: undo),
      ),
    );
}

/// Asks for a new name for a saved request; null when cancelled or empty.
Future<String?> askRequestName(BuildContext context, String current) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _TextDialog(
      title: 'Rename request',
      action: 'Rename',
      fieldKey: const Key('request-name'),
      hint: 'Request name',
      lines: 1,
      initial: current,
      url: false,
    ),
  );
  return (name == null || name.trim().isEmpty) ? null : name.trim();
}

// Async actions look the messenger up before their first await, so they can
// still report after the widget that started them is gone.
void _notify(ScaffoldMessengerState messenger, String message) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// `orders.postman_collection.json` -> `orders`.
String nameHintFor(String fileName) {
  var name = fileName;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  for (final suffix in const ['.postman_collection', '.postman_environment']) {
    if (name.endsWith(suffix)) {
      name = name.substring(0, name.length - suffix.length);
    }
  }
  return name;
}

String _fileSafe(String name) {
  final safe = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  return safe.isEmpty ? 'export' : safe;
}

String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

/// Lets the user pick a file and imports whatever it contains.
Future<void> importFromFile(BuildContext context, WorkspaceStore store) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    if (!context.mounted) return;
    await importFromText(context, store, text, nameHintFor(file.name));
  } catch (e) {
    _notify(messenger, 'Import failed: $e');
  }
}

/// Asks for pasted text, such as a curl command, and imports it.
Future<void> importFromPaste(BuildContext context, WorkspaceStore store) async {
  final text = await showDialog<String>(
    context: context,
    builder: (_) => const _TextDialog(
      title: 'Paste to import',
      action: 'Import',
      fieldKey: Key('paste'),
      hint:
          "curl https://api.example.com -H 'Accept: application/json'\n\n"
          'or OpenAPI / Postman / reqorb JSON, or KEY=value lines',
      lines: 8,
    ),
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  await importFromText(context, store, text, 'Pasted');
}

/// Asks for a collection name; null when cancelled or left empty.
Future<String?> _askCollectionName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _TextDialog(
      title: title,
      action: action,
      fieldKey: const Key('collection-name'),
      hint: 'Collection name',
      lines: 1,
      initial: initial,
      url: false,
    ),
  );
  return (name == null || name.trim().isEmpty) ? null : name.trim();
}

Future<void> newCollection(BuildContext context, WorkspaceStore store) async {
  final name = await _askCollectionName(
    context,
    title: 'New collection',
    action: 'Create',
  );
  if (name != null) store.addCollection(name);
}

Future<void> renameCollection(
  BuildContext context,
  WorkspaceStore store,
  int index,
) async {
  final collection = store.collections[index];
  final name = await _askCollectionName(
    context,
    title: 'Rename collection',
    action: 'Rename',
    initial: collection.name,
  );
  // Look the collection up again in case the list changed meanwhile.
  final current = store.collections.indexOf(collection);
  if (name != null && current >= 0) store.renameCollection(current, name);
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.action,
    required this.fieldKey,
    required this.hint,
    required this.lines,
    this.helper,
    this.initial = '',
    this.url = true,
  });

  /// Text the field starts with, selected so typing replaces it.
  final String initial;

  /// Whether a single-line field holds a URL rather than a name.
  final bool url;

  final String title;
  final String action;
  final Key fieldKey;
  final String hint;
  final String? helper;
  final int lines;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  // Owned by the dialog so it outlives the closing animation.
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final single = widget.lines == 1;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: TextField(
          key: widget.fieldKey,
          smartQuotesType: SmartQuotesType.disabled,
          smartDashesType: SmartDashesType.disabled,
          controller: _controller,
          autofocus: true,
          maxLines: single ? 1 : widget.lines + 2,
          minLines: single ? 1 : widget.lines - 2,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: !single
              ? TextInputType.multiline
              : widget.url
              ? TextInputType.url
              : TextInputType.text,
          textCapitalization: widget.url
              ? TextCapitalization.none
              : TextCapitalization.sentences,
          style: widget.url ? mono : null,
          decoration: InputDecoration(
            isDense: false,
            hintText: widget.hint,
            helperText: widget.helper,
          ),
          onSubmitted: single ? (_) => _submit() : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('dialog-confirm'),
          onPressed: _submit,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

Future<void> importFromText(
  BuildContext context,
  WorkspaceStore store,
  String text,
  String nameHint,
) => _runImport(
  context,
  store,
  () => importText(text: text, nameHint: nameHint),
);

/// Asks for a URL, such as a served `swagger.json`, and imports it.
Future<void> importFromUrl(BuildContext context, WorkspaceStore store) async {
  final url = await showDialog<String>(
    context: context,
    builder: (_) => const _TextDialog(
      title: 'Import from URL',
      action: 'Import',
      fieldKey: Key('import-url-field'),
      hint: 'https://api.example.com/swagger.json',
      helper: 'OpenAPI / Swagger (JSON or YAML), Postman or reqorb JSON',
      lines: 1,
    ),
  );
  if (url == null || url.trim().isEmpty || !context.mounted) return;
  final address = url.trim();
  await _runImport(
    context,
    store,
    () => importUrl(url: address.contains('://') ? address : 'http://$address'),
  );
}

Future<void> _runImport(
  BuildContext context,
  WorkspaceStore store,
  Future<ImportResult> Function() load,
) async {
  final messenger = ScaffoldMessenger.of(context);
  ImportResult result;
  try {
    result = await load();
  } catch (e) {
    _notify(messenger, 'Import failed: $e');
    return;
  }
  // A single new collection is named by the user; cancelling drops the import.
  if (result.collections.length == 1) {
    if (!context.mounted) return;
    final found = result.collections.single;
    final name = await _askCollectionName(
      context,
      title: 'Name this collection',
      action: 'Save',
      initial: found.name,
    );
    if (name == null) return;
    result = ImportResult(
      source: result.source,
      collections: [
        Collection(name: name, variables: found.variables, items: found.items),
      ],
      environments: result.environments,
      warnings: result.warnings,
    );
  }
  store.merge(result);
  final summary =
      'Imported ${_plural(result.collections.length, 'collection')} and '
      '${_plural(result.environments.length, 'environment')}';
  if (result.warnings.isEmpty || !context.mounted) {
    _notify(messenger, summary);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(summary),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Text(
            'Some things could not be carried over:\n\n'
            '${result.warnings.map((w) => '• $w').join('\n')}',
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('warnings-ok'),
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Asks where to save a file and writes it; tests replace this so that no
/// system dialog opens.
@visibleForTesting
Future<Object?> Function({required String fileName, required Uint8List bytes})
fileSaver = _pickAndSave;

Future<Object?> _pickAndSave({
  required String fileName,
  required Uint8List bytes,
}) => FilePicker.saveFile(fileName: fileName, bytes: bytes);

/// Saves every exchange of the session as an HTTP Archive.
Future<void> exportSessionHar(BuildContext context, WorkspaceStore store) =>
    _saveExport(
      context,
      'session.har',
      () async => exportHar(exchanges: store.session),
    );

/// Saves [text] to a file the user chooses, suggesting [fileName].
Future<void> saveTextFile(BuildContext context, String fileName, String text) =>
    _saveExport(context, fileName, () async => text);

Future<void> _saveExport(
  BuildContext context,
  String fileName,
  Future<String> Function() render,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final text = await render();
    final saved = await fileSaver(fileName: fileName, bytes: utf8.encode(text));
    if (saved != null) _notify(messenger, 'Exported $fileName');
  } catch (e) {
    _notify(messenger, 'Export failed: $e');
  }
}

Future<void> exportCollectionFile(
  BuildContext context,
  Collection collection,
  ExportFormat format,
) {
  final suffix = switch (format) {
    ExportFormat.postman => '.postman_collection',
    ExportFormat.bruno => '.bruno',
    _ => '',
  };
  final extension = exportExtension(format: format);
  return _saveExport(
    context,
    '${_fileSafe(collection.name)}$suffix.$extension',
    () => exportCollection(collection: collection, format: format),
  );
}

Future<void> exportEnvironmentFile(
  BuildContext context,
  Environment environment,
  ExportFormat format,
) {
  final suffix = format == ExportFormat.postman ? '.postman_environment' : '';
  final extension = exportExtension(format: format);
  return _saveExport(
    context,
    '${_fileSafe(environment.name)}$suffix.$extension',
    () => exportEnvironment(environment: environment, format: format),
  );
}
