import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';

const _methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];

/// Other kinds of request, chosen where an HTTP method would be.
const _protocols = ['WS', 'GRPC'];

/// The method and URL in one field, as they are read together.
class UrlBar extends StatefulWidget {
  const UrlBar({
    super.key,
    required this.method,
    required this.onMethodChanged,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    this.onCurl,
  });

  /// An HTTP method, or `WS` or `GRPC`.
  final String method;
  final ValueChanged<String> onMethodChanged;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Called when Return is pressed in the URL.
  final VoidCallback onSubmitted;

  /// Called with a curl command pasted in place of an address.
  final ValueChanged<String>? onCurl;

  @override
  State<UrlBar> createState() => _UrlBarState();
}

class _UrlBarState extends State<UrlBar> {
  /// What the field holds, and what it held before that, however it was
  /// changed: by typing, or by another request being shown in it.
  late String _now = widget.controller.text;
  late String _before = _now;

  String get method => widget.method;
  ValueChanged<String> get onMethodChanged => widget.onMethodChanged;
  TextEditingController get controller => widget.controller;
  FocusNode get focusNode => widget.focusNode;
  VoidCallback get onSubmitted => widget.onSubmitted;

  @override
  void initState() {
    super.initState();
    controller.addListener(_track);
  }

  @override
  void didUpdateWidget(UrlBar old) {
    super.didUpdateWidget(old);
    if (old.controller != controller) {
      old.controller.removeListener(_track);
      controller.addListener(_track);
      _before = _now = controller.text;
    }
  }

  @override
  void dispose() {
    controller.removeListener(_track);
    super.dispose();
  }

  void _track() {
    if (controller.text == _now) return;
    _before = _now;
    _now = controller.text;
  }

  static bool _isCurl(String text) =>
      text.trimLeft().toLowerCase().startsWith('curl ');

  /// A command arrives all at once. One typed letter by letter is left
  /// alone: as it becomes one it is only `curl `, with nothing after.
  void _changed(String text) {
    if (_isCurl(text) && !_isCurl(_before) && text.trim().length > 5) {
      widget.onCurl?.call(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: focusNode.hasFocus ? scheme.primary : scheme.outlineVariant,
            width: 1.5,
          ),
        ),
        child: child,
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 2),
            child: DropdownButton<String>(
              key: const Key('method'),
              value: method,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                // Imported requests may use a method outside the usual list.
                for (final m in {..._methods, ..._protocols, method})
                  DropdownMenuItem(
                    value: m,
                    child: Text(
                      m,
                      style: mono.copyWith(
                        color: methodColor(m, theme.brightness),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
              onChanged: (m) {
                if (m != null) onMethodChanged(m);
              },
            ),
          ),
          SizedBox(
            height: 22,
            child: VerticalDivider(width: 9, color: scheme.outlineVariant),
          ),
          Expanded(
            child: TextField(
              key: const Key('url'),
              focusNode: focusNode,
              smartQuotesType: SmartQuotesType.disabled,
              smartDashesType: SmartDashesType.disabled,
              controller: controller,
              autocorrect: false,
              keyboardType: TextInputType.url,
              style: mono,
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 11,
                ),
                hintText: 'Enter a URL, or paste one: {{base_url}}/users',
              ),
              onChanged: _changed,
              onSubmitted: (_) => onSubmitted(),
            ),
          ),
        ],
      ),
    );
  }
}
