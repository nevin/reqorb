/// Importing collections and environments from a file, a URL or pasted text.
library;

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/shared/text_dialog.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/collection_actions.dart';
import 'package:reqorb/workspace/workspace_store.dart';

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
    notify(messenger, 'Import failed: $e');
  }
}

/// Asks for pasted text, such as a curl command, and imports it.
Future<void> importFromPaste(BuildContext context, WorkspaceStore store) async {
  final text = await showDialog<String>(
    context: context,
    builder: (_) => const TextDialog(
      title: 'Paste to import',
      action: 'Import',
      fieldKey: Key('paste'),
      hint:
          "curl https://api.example.com -H 'Accept: application/json'\n\n"
          'or OpenAPI / Postman / HAR / reqorb JSON, or KEY=value lines',
      lines: 8,
    ),
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  await importFromText(context, store, text, 'Pasted');
}

Future<void> importFromText(
  BuildContext context,
  WorkspaceStore store,
  String text,
  String nameHint,
) {
  final engine = Engine.of(context);
  return runImport(
    context,
    store,
    () => engine.importText(text: text, nameHint: nameHint),
  );
}

/// Asks for a URL, such as a served `swagger.json`, and imports it.
Future<void> importFromUrl(BuildContext context, WorkspaceStore store) async {
  final url = await showDialog<String>(
    context: context,
    builder: (_) => const TextDialog(
      title: 'Import from URL',
      action: 'Import',
      fieldKey: Key('import-url-field'),
      hint: 'https://api.example.com/swagger.json',
      helper: 'OpenAPI / Swagger (JSON or YAML), Postman, HAR or reqorb JSON',
      lines: 1,
    ),
  );
  if (url == null || url.trim().isEmpty || !context.mounted) return;
  final address = url.trim();
  final engine = Engine.of(context);
  await runImport(
    context,
    store,
    () => engine.importUrl(
      url: address.contains('://') ? address : 'http://$address',
    ),
  );
}

Future<void> runImport(
  BuildContext context,
  WorkspaceStore store,
  Future<ImportResult> Function() load,
) async {
  final messenger = ScaffoldMessenger.of(context);
  ImportResult result;
  try {
    result = await load();
  } catch (e) {
    notify(messenger, 'Import failed: $e');
    return;
  }
  // A single new collection is named by the user; cancelling drops the import.
  if (result.collections.length == 1) {
    if (!context.mounted) return;
    final found = result.collections.single;
    final name = await askCollectionName(
      context,
      title: 'Name this collection',
      action: 'Save',
      initial: found.name,
    );
    if (name == null) return;
    result = ImportResult(
      source: result.source,
      collections: [
        Collection(
          name: name,
          variables: found.variables,
          items: found.items,
          untrustedScripts: found.untrustedScripts,
        ),
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
    notify(messenger, summary);
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
