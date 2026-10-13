/// Saving exports to files, with the option to redact them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

String _fileSafe(String name) {
  final safe = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  return safe.isEmpty ? 'export' : safe;
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

/// Saves generated code to a file the user chooses, suggesting
/// [fileName]. It is written as shown, which is how it has to run.
Future<void> saveCodeFile(
  BuildContext context,
  String fileName,
  String code,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final saved = await fileSaver(fileName: fileName, bytes: utf8.encode(code));
    if (saved != null) notify(messenger, 'Saved $fileName');
  } catch (e) {
    notify(messenger, 'Could not save the code: $e');
  }
}

/// Whether the last export was redacted, offered again as the default.
bool _redact = false;

/// Confirms an export of [what] and asks whether to redact it. Returns null
/// when cancelled, otherwise whether sensitive data should be taken out.
Future<bool?> _askExport(BuildContext context, String what, String covers) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _ExportDialog(what: what, covers: covers),
    );

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.what, required this.covers});

  final String what;

  /// Where redaction looks, so the promise matches what is exported.
  final String covers;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Export ${widget.what}'),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 420,
        child: CheckboxListTile(
          key: const Key('export-redact'),
          value: _redact,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Redact sensitive data'),
          subtitle: Text(
            'Replaces tokens, passwords, cookies and keys in '
            '${widget.covers} with [REDACTED]. Check the file before '
            'sharing it: secrets under other names are not found.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          onChanged: (value) => setState(() => _redact = value ?? false),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('export-confirm'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, _redact),
          child: const Text('Export…'),
        ),
      ],
    );
  }
}

/// Saves every exchange of the session as an HTTP Archive.
Future<void> exportSessionHar(BuildContext context, WorkspaceStore store) {
  final engine = Engine.of(context);
  return _saveExport(
    context,
    'session.har',
    what: 'session as HAR',
    covers: 'headers, URLs and JSON or form bodies',
    (redact) async => engine.exportHar(
      exchanges: redact
          ? engine.redactExchanges(exchanges: store.session)
          : store.session,
    ),
  );
}

/// Saves [bytes] as they are to a file the user chooses.
Future<void> saveBytesFile(
  BuildContext context,
  String fileName,
  Uint8List bytes,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final saved = await fileSaver(fileName: fileName, bytes: bytes);
    if (saved != null) notify(messenger, 'Saved $fileName');
  } catch (e) {
    notify(messenger, 'Could not save the file: $e');
  }
}

/// Saves [text] to a file the user chooses, suggesting [fileName].
Future<void> saveTextFile(BuildContext context, String fileName, String text) {
  final engine = Engine.of(context);
  return _saveExport(
    context,
    fileName,
    what: 'response body',
    covers: 'a JSON body',
    (redact) async => redact ? engine.redactText(text: text) : text,
  );
}

Future<void> _saveExport(
  BuildContext context,
  String fileName,
  Future<String> Function(bool redact) render, {
  required String what,
  required String covers,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final redact = await _askExport(context, what, covers);
  if (redact == null) return;
  try {
    final text = await render(redact);
    final saved = await fileSaver(fileName: fileName, bytes: utf8.encode(text));
    if (saved != null) {
      notify(
        messenger,
        redact ? 'Exported $fileName, redacted' : 'Exported $fileName',
      );
    }
  } catch (e) {
    notify(messenger, 'Export failed: $e');
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
  final engine = Engine.of(context);
  final extension = engine.exportExtension(format: format);
  return _saveExport(
    context,
    '${_fileSafe(collection.name)}$suffix.$extension',
    what: 'collection',
    covers: 'headers, URLs, authorization, bodies and variables',
    (redact) => engine.exportCollection(
      collection: redact
          ? engine.redactCollection(collection: collection)
          : collection,
      format: format,
    ),
  );
}

Future<void> exportEnvironmentFile(
  BuildContext context,
  Environment environment,
  ExportFormat format,
) {
  final suffix = format == ExportFormat.postman ? '.postman_environment' : '';
  final engine = Engine.of(context);
  final extension = engine.exportExtension(format: format);
  return _saveExport(
    context,
    '${_fileSafe(environment.name)}$suffix.$extension',
    what: 'environment',
    covers: 'variables',
    (redact) => engine.exportEnvironment(
      environment: redact
          ? engine.redactEnvironment(environment: environment)
          : environment,
      format: format,
    ),
  );
}
