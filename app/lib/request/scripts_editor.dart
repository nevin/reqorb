import 'package:flutter/material.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/syntax.dart';

/// The Scripts tab: JavaScript that prepares the request before it is
/// sent, and JavaScript that tests the response and keeps values from it.
class ScriptsEditor extends StatelessWidget {
  const ScriptsEditor({
    super.key,
    required this.before,
    required this.after,
    this.variables = const [],
  });

  final CodeController before;
  final CodeController after;

  /// Names of the variables in reach, offered after `{{`.
  final List<String> variables;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelLarge;
    final help = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Before the request', style: label),
          const SizedBox(height: 2),
          Text(
            'JavaScript run before each send. Change request.url, '
            'request.body or request.setHeader(name, value), and set '
            'variables with vars.set(name, value).',
            style: help,
          ),
          const SizedBox(height: 6),
          _field(
            'pre-script',
            before,
            "vars.set('stamp', Date.now());\n"
                "request.setHeader('X-Stamp', '{{stamp}}');",
          ),
          const SizedBox(height: 16),
          Text('After the response', style: label),
          const SizedBox(height: 2),
          Text(
            'JavaScript run on each response. Read response.status, '
            'response.json() and response.header(name); check them with '
            'test(name, fn) and expect(value); keep values with vars.set. '
            'Scripts written for Postman with pm.* run as they are.',
            style: help,
          ),
          const SizedBox(height: 6),
          _field(
            'post-script',
            after,
            "test('is an order', () => {\n"
                "  expect(response.status).toBe(200);\n"
                "  expect(response.json().id).toBeGreaterThan(0);\n"
                '});',
          ),
        ],
      ),
    );
  }

  Widget _field(String name, CodeController controller, String hint) => CodeBox(
    height: 190,
    child: CodeEditor(
      name: name,
      controller: controller,
      language: CodeLanguage.javascript,
      hint: hint,
      hintLines: 4,
      variables: variables,
    ),
  );
}
