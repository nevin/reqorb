import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';

const _methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];

/// Other kinds of request, chosen where an HTTP method would be.
const _protocols = ['WS', 'GRPC'];

/// The method and URL in one field, as they are read together.
class UrlBar extends StatelessWidget {
  const UrlBar({
    super.key,
    required this.method,
    required this.onMethodChanged,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
  });

  /// An HTTP method, or `WS` or `GRPC`.
  final String method;
  final ValueChanged<String> onMethodChanged;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Called when Return is pressed in the URL.
  final VoidCallback onSubmitted;

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
              onSubmitted: (_) => onSubmitted(),
            ),
          ),
        ],
      ),
    );
  }
}
