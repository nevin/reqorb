import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/document/memory_document.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/document_view.dart';
import 'package:reqorb/editor/syntax.dart';

/// How long typing pauses before an edit is written back.
const _pause = Duration(milliseconds: 250);

/// Text too long for a text field, edited all the same: held in a
/// document while it is shown, and written back to [controller] once
/// typing pauses, as copying the whole text takes a moment. It is written
/// back at once whenever what reads the controller may be about to: on a
/// shortcut, a click anywhere else, leaving the text, and the app going
/// to the background or closing.
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

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _code.addListener(_controllerChanged);
    _lifecycle = AppLifecycleListener(
      onInactive: _flush,
      onHide: _flush,
      onPause: _flush,
    );
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
    _lifecycle.dispose();
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
    _soon?.cancel();
    _soon = Timer(_pause, _flush);
  }

  /// A shortcut, such as one that sends or saves, finds the text written
  /// back. Nothing is done with the key here.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        (keyboard.isMetaPressed || keyboard.isControlPressed)) {
      _flush();
    }
    return KeyEventResult.ignored;
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
    // A click elsewhere, as on a button that sends, is a pointer going
    // down before the button acts on its coming up.
    return TapRegion(
      onTapOutside: (_) => _flush(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _key,
        // Leaving the text writes the last of it back.
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
      ),
    );
  }
}
