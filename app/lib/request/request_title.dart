import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/shared/theme.dart';

/// The open request's name, where it is saved, and whether it has unsaved
/// edits. Double-clicking or long-pressing the name edits it in place.
///
/// Give it a new [key] when another request is opened, so that a name being
/// typed is not carried over.
class RequestTitle extends StatefulWidget {
  const RequestTitle({
    super.key,
    required this.name,
    required this.collection,
    required this.dirty,
    required this.onRename,
  });

  /// Null for a request that has not been named yet.
  final String? name;

  /// The collection the request is saved in, if any.
  final String? collection;

  /// Whether the request differs from its saved copy.
  final bool dirty;

  /// Called with the new name, which is never empty.
  final ValueChanged<String> onRename;

  @override
  State<RequestTitle> createState() => _RequestTitleState();
}

class _RequestTitleState extends State<RequestTitle> {
  bool _editing = false;
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Clicking away keeps what was typed.
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _edit() {
    final name = widget.name ?? '';
    _text
      ..text = name
      ..selection = TextSelection(baseOffset: 0, extentOffset: name.length);
    setState(() => _editing = true);
  }

  void _commit() {
    if (!_editing) return;
    final name = _text.text.trim();
    setState(() => _editing = false);
    if (name.isNotEmpty) widget.onRename(name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    const strong = TextStyle(fontWeight: FontWeight.w600);
    final name = widget.name;
    final collection = widget.collection == null
        ? null
        : '${widget.collection}  /  ';

    final Widget label;
    if (_editing) {
      label = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (collection != null) Text(collection, style: muted),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: CallbackShortcuts(
                bindings: {
                  // Escape leaves the name as it was.
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      setState(() => _editing = false),
                },
                child: TextField(
                  key: const Key('title-field'),
                  controller: _text,
                  focusNode: _focus,
                  autofocus: true,
                  style: theme.textTheme.bodyMedium?.merge(strong),
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Request name',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                  ),
                  onSubmitted: (_) => _commit(),
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      final text = Text.rich(
        TextSpan(
          children: [
            if (collection != null) TextSpan(text: collection, style: muted),
            TextSpan(
              text: name ?? 'Untitled request',
              style: name == null ? muted : strong,
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      final target = GestureDetector(
        key: const Key('title'),
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _edit,
        onLongPress: _edit,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: text,
        ),
      );
      // The hint wraps the gesture target, because a tooltip inside it would
      // win the long press; on touch screens it is left out altogether.
      label = isDesktop
          ? Tooltip(message: 'Double-click to rename', child: target)
          : target;
    }
    return Row(
      children: [
        Flexible(child: label),
        if (widget.dirty)
          Tooltip(
            message: 'Unsaved changes (${shortcutModifier}S to save)',
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 8, color: scheme.primary),
                  const SizedBox(width: 5),
                  Text(
                    'Edited',
                    key: const Key('unsaved'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
