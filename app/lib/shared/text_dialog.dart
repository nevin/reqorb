/// A dialog that asks for one piece of text.
library;

import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';

class TextDialog extends StatefulWidget {
  const TextDialog({
    super.key,
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
  State<TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<TextDialog> {
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
