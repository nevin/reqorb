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
import 'package:reqorb/editor/hex_view.dart';
import 'package:reqorb/editor/json_tree_view.dart';
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

/// Saves a copy of the file at [from], suggesting [name]: where the user
/// chooses on the desktop, and handed to the platform to export on iPad,
/// which needs it all in memory, so at most [_exportLimit] of it.
Future<void> saveCopyOf(BuildContext context, String from, String name) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (_savesInPlace) {
      final to = await chooseSavePath(name);
      if (to == null) return;
      await File(from).copy(to);
      notify(messenger, 'Saved ${_nameOf(to)}');
      return;
    }
    final len = await File(from).length();
    if (len > _exportLimit) {
      notify(
        messenger,
        'At most ${_exportLimit >> 20} MB can be exported at once.',
      );
      return;
    }
    await FilePicker.saveFile(
      fileName: name,
      bytes: await File(from).readAsBytes(),
    );
  } catch (e) {
    notify(messenger, 'Could not save $name: $e');
  }
}

/// Asks for a file and opens it to edit.
Future<void> openFile(BuildContext context) async {
  final path = await pickDocumentPath();
  if (path == null || !context.mounted) return;
  await showFile(context, path);
}

/// Opens the file at [path] to edit, however large. A [temporary] file,
/// such as a response kept on disk, is shown as [name] and saved only
/// elsewhere.
Future<void> showFile(
  BuildContext context,
  String path, {
  bool temporary = false,
  String? name,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => FilePage(path: path, temporary: temporary, name: name),
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
  const FilePage({
    super.key,
    required this.path,
    this.temporary = false,
    this.name,
  });

  final String path;

  /// Whether the file is one of the app's own, kept only for now, which
  /// saving puts somewhere else rather than writing.
  final bool temporary;

  /// What to call it, in place of its file name.
  final String? name;

  @override
  State<FilePage> createState() => _FilePageState();
}

class _FilePageState extends State<FilePage> {
  late String _path = widget.path;
  TextDocument? _doc;
  String? _error;
  bool _opening = true;

  /// How the file is shown: as text, as bytes, or as a JSON tree. A file
  /// that looks binary starts as bytes.
  _View _view = _View.text;

  /// Whether the text is JSON written out again, not yet saved over the
  /// file: the document is then a temporary file of its own.
  bool _rewritten = false;

  /// How far writing the JSON out again has got, while it is going.
  double? _rewriting;
  StreamSubscription<DocFormatUpdate>? _rewrite;

  /// Whether the file was changed elsewhere while there are changes here.
  bool _changedElsewhere = false;
  bool _saving = false;

  /// Looks for changes made to the file by other programs.
  Timer? _watch;

  /// Counts opens, so that one finishing after a later one is dropped.
  int _opens = 0;

  /// Still the app's temporary file, not yet saved anywhere of the user's.
  bool get _temporary => widget.temporary && _path == widget.path;

  String get _name =>
      _temporary ? (widget.name ?? _nameOf(_path)) : _nameOf(_path);

  bool get _modified => (_doc?.info().modified ?? false) || _rewritten;

  CodeLanguage? get _language => CodeLanguage.ofFileName(_name);

  bool get _json => _language == CodeLanguage.json;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_doc == null && _error == null && _opens == 0) _open(_path);
  }

  @override
  void dispose() {
    _watch?.cancel();
    _rewrite?.cancel();
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
      _view = (doc?.looksBinary ?? false) ? _View.hex : _View.text;
      _changedElsewhere = false;
      _rewritten = false;
      _rewriting = null;
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
    if (doc == null ||
        _saving ||
        _changedElsewhere ||
        _rewritten ||
        !doc.changedOnDisk) {
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
    if (_temporary) {
      await _saveAs();
      return;
    }
    // JSON written out again is in a file of its own, saved over this one.
    await _saveTo(doc, _rewritten ? _path : null, force: _rewritten);
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
        _rewritten = false;
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
        return _saveTo(doc, _rewritten ? _path : null, force: _rewritten);
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

  /// Writes the JSON out again, indented by [indent] or minified, into a
  /// file of its own, and shows that in place of the text, to save over
  /// the file. It takes the text with any edits as it is when asked; undo
  /// starts afresh after.
  void _rewriteJson({String? indent}) {
    final doc = _doc;
    if (doc == null || _rewrite != null) return;
    final messenger = ScaffoldMessenger.of(context);
    final engine = Engine.of(context);
    setState(() => _rewriting = 0);
    _rewrite = doc.formatJson(indent: indent).listen((u) async {
      if (!mounted) return;
      if (!u.done) {
        setState(() => _rewriting = u.total == 0 ? null : u.read / u.total);
        return;
      }
      _rewrite = null;
      final path = u.path;
      if (path == null) {
        setState(() => _rewriting = null);
        notify(messenger, 'Could not format $_name: ${u.error}');
        return;
      }
      final rewritten = await engine.openDocument(path);
      if (!mounted || doc != _doc) return rewritten.dispose();
      doc.dispose();
      setState(() {
        _doc = rewritten;
        _rewritten = true;
        _rewriting = null;
      });
      notify(
        messenger,
        indent == null
            ? 'Minified; saving writes it over $_name'
            : 'Formatted; saving writes it over $_name',
      );
    });
  }

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
          if (_rewriting != null || _rewrite != null)
            LinearProgressIndicator(
              key: const Key('file-rewriting'),
              minHeight: 2,
              value: _rewriting,
            ),
          if (_view == _View.hex)
            Expanded(
              child: HexView(
                key: ValueKey(doc),
                document: doc,
                name: 'file-hex',
              ),
            )
          else if (_view == _View.tree)
            Expanded(
              child: JsonTreeView(
                key: ValueKey(doc),
                document: doc,
                name: 'file-tree',
              ),
            )
          else
            Expanded(
              child: DocumentView(
                key: ValueKey(doc),
                document: doc,
                name: 'file',
                language: _language,
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
                  _temporary
                      ? 'Not saved anywhere yet'
                      : File(_path).parent.path,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              if (doc != null)
                PopupMenuButton<VoidCallback>(
                  key: const Key('file-view'),
                  tooltip: 'Show as',
                  icon: Icon(switch (_view) {
                    _View.text => Icons.notes,
                    _View.hex => Icons.memory,
                    _View.tree => Icons.account_tree_outlined,
                  }),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      key: const Key('file-view-text'),
                      checked: _view == _View.text,
                      value: () => setState(() => _view = _View.text),
                      child: const Text('Text'),
                    ),
                    CheckedPopupMenuItem(
                      key: const Key('file-view-hex'),
                      checked: _view == _View.hex,
                      value: () => setState(() => _view = _View.hex),
                      child: const Text('Bytes'),
                    ),
                    if (_json) ...[
                      CheckedPopupMenuItem(
                        key: const Key('file-view-tree'),
                        checked: _view == _View.tree,
                        value: () => setState(() => _view = _View.tree),
                        child: const Text('JSON tree'),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        key: const Key('file-format'),
                        enabled: _rewrite == null,
                        value: () => _rewriteJson(indent: CodeStyle.indent),
                        child: const Text('Format JSON'),
                      ),
                      PopupMenuItem(
                        key: const Key('file-minify'),
                        enabled: _rewrite == null,
                        value: _rewriteJson,
                        child: const Text('Minify JSON'),
                      ),
                    ],
                  ],
                ),
              IconButton(
                key: const Key('file-open'),
                tooltip: 'Open another (${shortcutModifier}O)',
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: _openAnother,
              ),
              if (_savesInPlace) ...[
                if (!_temporary)
                  IconButton(
                    key: const Key('file-save'),
                    tooltip: 'Save (${shortcutModifier}S)',
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    onPressed: doc == null || !modified || _saving
                        ? null
                        : _save,
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

/// How a file is shown.
enum _View { text, hex, tree }
