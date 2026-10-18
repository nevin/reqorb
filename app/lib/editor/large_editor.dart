import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/document/memory_document.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/document_view.dart';
import 'package:reqorb/editor/syntax.dart';

/// Up to this size, an edit is written back to the controller at once;
/// past it, once typing pauses, as copying the whole text takes a moment.
const _writeAtOnce = 4 * 1024 * 1024;

/// Text too long for a text field, edited all the same: held in a
/// document while it is shown, and written back to [controller] as it
/// changes, so that whatever reads the controller sees every edit.
///
/// Keyed as [DocumentView] keys it, by [name].
class LargeEditor extends StatefulWidget {
  const LargeEditor({
    super.key,
    required this.name,
    required this.controller,
    this.language,
    this.readOnly = false,
  });

  final String name;
  final CodeController controller;
  final CodeLanguage? language;
  final bool readOnly;

  @override
  State<LargeEditor> createState() => _LargeEditorState();
}

class _LargeEditorState extends State<LargeEditor> {
  TextDocument? _document;

  /// The text last taken from or given to the controller.
  String _known = '';

  /// Writes the latest edits back once typing pauses.
  Timer? _soon;
  bool _writing = false;

  CodeController get _code => widget.controller;

  @override
  void initState() {
    super.initState();
    _code.addListener(_controllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _document ??= _make(_code.text);
  }

  @override
  void didUpdateWidget(LargeEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _flush();
      old.controller.removeListener(_controllerChanged);
      _code.addListener(_controllerChanged);
      _replaceDocument(_code.text);
    }
  }

  @override
  void dispose() {
    _flush();
    _code.removeListener(_controllerChanged);
    _document?.dispose();
    super.dispose();
  }

  TextDocument _make(String text) {
    _known = text;
    return Engine.maybeOf(context)?.documentOf(text) ?? MemoryDocument(text);
  }

  void _replaceDocument(String text) {
    _document?.dispose();
    setState(() => _document = _make(text));
  }

  /// Text set on the controller from elsewhere, as when another request is
  /// opened, replaces what is shown.
  void _controllerChanged() {
    if (_writing) return;
    final text = _code.text;
    if (identical(text, _known) || text == _known) return;
    _soon?.cancel();
    _replaceDocument(text);
  }

  void _edited() {
    final len = _document?.info().len ?? 0;
    _soon?.cancel();
    if (len <= _writeAtOnce) {
      _flush();
    } else {
      _soon = Timer(const Duration(milliseconds: 250), _flush);
    }
  }

  /// Writes the document's text back to the controller, if it has
  /// changed since.
  void _flush() {
    _soon?.cancel();
    _soon = null;
    final document = _document;
    if (document == null) return;
    final text = document.text(0, document.info().len);
    if (text == _known) return;
    _known = text;
    _writing = true;
    try {
      _code.value = TextEditingValue(
        text: text,
        selection: const TextSelection.collapsed(offset: 0),
      );
    } finally {
      _writing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = _document!;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      // Leaving the text writes the last of it back, so that a send or a
      // save right after sees it.
      onFocusChange: (focused) {
        if (!focused) _flush();
      },
      child: DocumentView(
        key: ValueKey(document),
        document: document,
        name: widget.name,
        language: widget.language,
        editable: !widget.readOnly,
        lineSought: _code.lineNumberSought,
        onLink: _code.onLink,
        onChanged: _edited,
      ),
    );
  }
}
