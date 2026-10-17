import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/document_view.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/shared/theme.dart';

/// Asks for a file to open, and returns its path, or null when cancelled.
/// Tests replace this so that no system dialog opens.
@visibleForTesting
Future<String?> Function() pickDocumentPath = () async =>
    (await FilePicker.pickFile(dialogTitle: 'Open a file'))?.path;

/// Asks where to save a copy, suggesting [name], and returns the path, or
/// null when cancelled. On macOS the panel leaves an empty file there,
/// which is what lets a sandboxed app write it. Tests replace this.
@visibleForTesting
Future<String?> Function(String name) chooseSavePath = (name) async {
  final chosen = await FilePicker.saveFile(
    fileName: name,
    bytes: Uint8List(0),
    dialogTitle: 'Save as',
  );
  return chosen?.toFilePath();
};

/// Whether a file opened can be saved where it is. On iOS and Android a
/// picked file is a copy in the app's own folder, so it is exported
/// instead.
bool get _savesInPlace => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

/// The most a document is exported at once where it cannot be saved in
/// place: exporting hands the whole text to the platform.
const _exportLimit = 64 * 1024 * 1024;

/// Asks for a file and opens it to edit.
Future<void> openFile(BuildContext context) async {
  final path = await pickDocumentPath();
  if (path == null || !context.mounted) return;
  await showFile(context, path);
}

/// Opens the file at [path] to edit, however large.
Future<void> showFile(BuildContext context, String path) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => FilePage(path: path),
      ),
    );

String _nameOf(String path) => path.split(Platform.pathSeparator).last;

/// A file of any size, to read and edit, and save: up to a gigabyte opens
/// at once, and only what is in view is read.
///
/// Keyed `file-page`; its actions `file-open`, `file-save`, `file-save-as`
/// and `file-export`; the editor `file`, as [DocumentView] keys it; and
/// the notice of a change made elsewhere `file-changed`, with
/// `file-reload` and `file-keep`.
class FilePage extends StatefulWidget {
  const FilePage({super.key, required this.path});

  final String path;

  @override
  State<FilePage> createState() => _FilePageState();
}

class _FilePageState extends State<FilePage> {
  late String _path = widget.path;
  TextDocument? _doc;
  String? _error;
  bool _opening = true;

  /// Whether the file looks binary, and is shown only when asked.
  bool _binary = false;

  /// Whether the file was changed elsewhere while there are changes here.
  bool _changedElsewhere = false;
  bool _saving = false;

  /// Looks for changes made to the file by other programs.
  Timer? _watch;

  /// Counts opens, so that one finishing after a later one is dropped.
  int _opens = 0;

  String get _name => _nameOf(_path);

  bool get _modified => _doc?.info().modified ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_doc == null && _error == null && _opens == 0) _open(_path);
  }

  @override
  void dispose() {
    _watch?.cancel();
    _doc?.dispose();
    super.dispose();
  }

  Future<void> _open(String path) async {
    final open = ++_opens;
    final engine = Engine.of(context);
    setState(() {
      _opening = true;
      _error = null;
    });
    TextDocument? doc;
    String? error;
    try {
      doc = await engine.openDocument(path);
    } catch (e) {
      error = '$e';
    }
    if (!mounted || open != _opens) {
      doc?.dispose();
      return;
    }
    _doc?.dispose();
    setState(() {
      _path = path;
      _doc = doc;
      _error = error;
      _opening = false;
      _binary = doc?.looksBinary ?? false;
      _changedElsewhere = false;
    });
    _watch?.cancel();
    if (doc != null) {
      _watch = Timer.periodic(const Duration(seconds: 2), (_) => _check());
    }
  }

  /// Takes in a change made to the file elsewhere: read again at once if
  /// there are no changes here to lose, and otherwise said.
  void _check() {
    final doc = _doc;
    if (doc == null || _saving || _changedElsewhere || !doc.changedOnDisk) {
      return;
    }
    if (!_modified) {
      final messenger = ScaffoldMessenger.of(context);
      _open(_path).then((_) {
        notify(messenger, '$_name was changed by another program; reloaded');
      });
      return;
    }
    setState(() => _changedElsewhere = true);
  }

  Future<void> _save() async {
    final doc = _doc;
    if (doc == null || _saving) return;
    if (!_savesInPlace) {
      await _export();
      return;
    }
    await _saveTo(doc, null);
  }

  Future<void> _saveAs() async {
    final doc = _doc;
    if (doc == null || _saving) return;
    final path = await chooseSavePath(_name);
    if (path == null || !mounted) return;
    // Chosen just now, so whatever is there goes.
    await _saveTo(doc, path, force: true);
  }

  /// Saves to [path], or where the file is. Saving over a file changed
  /// elsewhere is asked about first.
  Future<bool> _saveTo(
    TextDocument doc,
    String? path, {
    bool force = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      if (!force && path == null && doc.changedOnDisk) {
        force = await _confirmOverwrite();
        if (!force) return false;
      }
      await doc.save(path: path, force: force);
      if (!mounted) return true;
      setState(() {
        if (path != null) _path = path;
        _changedElsewhere = false;
      });
      notify(messenger, 'Saved $_name');
      return true;
    } catch (e) {
      notify(messenger, '$e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmOverwrite() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save over the other changes?'),
          content: Text(
            '$_name has been changed by another program since it was opened. '
            'Saving replaces those changes with yours.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('file-overwrite'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save over them'),
            ),
          ],
        ),
      ) ??
      false;

  /// Hands a copy to the platform to save, where the file cannot be saved
  /// in place.
  Future<void> _export() async {
    final doc = _doc;
    if (doc == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final len = doc.info().len;
    if (len > _exportLimit) {
      notify(
        messenger,
        'At most ${_exportLimit >> 20} MB can be exported at once.',
      );
      return;
    }
    try {
      await FilePicker.saveFile(
        fileName: _name,
        bytes: utf8.encode(doc.text(0, len)),
      );
    } catch (e) {
      notify(messenger, 'Could not export $_name: $e');
    }
  }

  /// Whether to go on and leave the changes: asks to save them, if there
  /// are any. True when there are none, or they were saved or dropped.
  Future<bool> _mayLeave() async {
    final doc = _doc;
    if (doc == null || !_modified) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Save the changes to $_name?'),
        content: const Text('They are lost if they are not saved.'),
        actions: [
          TextButton(
            key: const Key('file-discard'),
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text("Don't save"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('file-save-changes'),
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(_savesInPlace ? 'Save' : 'Export'),
          ),
        ],
      ),
    );
    switch (choice) {
      case 'discard':
        return true;
      case 'save':
        if (!_savesInPlace) {
          await _export();
          return false;
        }
        return _saveTo(doc, null);
      default:
        return false;
    }
  }

  Future<void> _openAnother() async {
    if (!await _mayLeave() || !mounted) return;
    final path = await pickDocumentPath();
    if (path == null || !mounted) return;
    await _open(path);
  }

  Future<void> _close() async {
    if (!await _mayLeave() || !mounted) return;
    Navigator.of(context).pop();
  }

  /// Drops the changes here for the file as it is now.
  void _reload() => _open(_path);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _doc;
    final modified = _modified;
    final mac =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    // Command on Apple's platforms, Control elsewhere.
    SingleActivator shortcut(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(key, meta: mac, control: !mac, shift: shift);

    final Widget body;
    if (_opening && doc == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (doc == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? '', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _openAnother,
                child: const Text('Open another file…'),
              ),
            ],
          ),
        ),
      );
    } else if (_binary) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.memory,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                '$_name looks like a binary file.',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                'Shown as text, it is mostly unreadable, and saving it after '
                'an edit could damage it.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                key: const Key('file-binary-open'),
                onPressed: () => setState(() => _binary = false),
                child: const Text('Show as text anyway'),
              ),
            ],
          ),
        ),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_changedElsewhere)
            MaterialBanner(
              key: const Key('file-changed'),
              content: Text(
                '$_name has been changed by another program. Reload it, '
                'losing your changes, or keep them and save over it later.',
              ),
              actions: [
                TextButton(
                  key: const Key('file-reload'),
                  onPressed: _reload,
                  child: const Text('Reload'),
                ),
                TextButton(
                  key: const Key('file-keep'),
                  onPressed: () => setState(() => _changedElsewhere = false),
                  child: const Text('Keep mine'),
                ),
              ],
            ),
          Expanded(
            child: DocumentView(
              key: ValueKey(doc),
              document: doc,
              name: 'file',
              language: CodeLanguage.ofFileName(_name),
              editable: true,
              status: true,
              autofocus: true,
              onChanged: () => setState(() {}),
            ),
          ),
        ],
      );
    }

    return PopScope(
      canPop: !modified,
      onPopInvokedWithResult: (popped, _) async {
        if (popped || !await _mayLeave() || !context.mounted) return;
        Navigator.pop(context);
      },
      child: CallbackShortcuts(
        bindings: {
          shortcut(LogicalKeyboardKey.keyS): _save,
          if (_savesInPlace)
            shortcut(LogicalKeyboardKey.keyS, shift: true): _saveAs,
          shortcut(LogicalKeyboardKey.keyO): _openAnother,
          shortcut(LogicalKeyboardKey.keyW): _close,
        },
        child: Scaffold(
          key: const Key('file-page'),
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${modified ? '• ' : ''}$_name',
                  key: const Key('file-title'),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  File(_path).parent.path,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                key: const Key('file-open'),
                tooltip: 'Open another (${shortcutModifier}O)',
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: _openAnother,
              ),
              if (_savesInPlace) ...[
                IconButton(
                  key: const Key('file-save'),
                  tooltip: 'Save (${shortcutModifier}S)',
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  onPressed: doc == null || !modified || _saving ? null : _save,
                ),
                IconButton(
                  key: const Key('file-save-as'),
                  tooltip: 'Save as… (⇧${shortcutModifier}S)',
                  icon: const Icon(Icons.save_as_outlined),
                  onPressed: doc == null || _saving ? null : _saveAs,
                ),
              ] else
                IconButton(
                  key: const Key('file-export'),
                  tooltip: 'Export…',
                  icon: const Icon(Icons.ios_share),
                  onPressed: doc == null ? null : _export,
                ),
            ],
          ),
          body: body,
        ),
      ),
    );
  }
}
