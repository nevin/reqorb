import 'package:flutter/material.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/code_controller.dart';

/// The lines of [text] that hold something.
List<String> linesOf(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

/// The Tests tab: checks the response must pass, and values to keep from it
/// for later requests. Both are written one per line.
class TestsEditor extends StatelessWidget {
  const TestsEditor({
    super.key,
    required this.tests,
    required this.captures,
    this.variables = const [],
  });

  final CodeController tests;
  final CodeController captures;

  /// Names of the variables in reach, offered after `{{`.
  final List<String> variables;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = theme.textTheme.labelLarge;
    final help = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tests', style: label),
          const SizedBox(height: 2),
          Text(
            'One per line, checked after each send. Read status, time, size, '
            'header NAME, body or body.path; compare with == != < <= > >= '
            'contains exists missing.',
            style: help,
          ),
          const SizedBox(height: 6),
          _field(
            'tests',
            tests,
            'status == 200\nbody.items[0].id exists\ntime < 500',
          ),
          const SizedBox(height: 16),
          Text('Capture', style: label),
          const SizedBox(height: 2),
          Text(
            'Keeps a value from the response as a variable for later requests, '
            'until the session is cleared. Use it as {{name}}.',
            style: help,
          ),
          const SizedBox(height: 6),
          _field(
            'captures',
            captures,
            'token = body.access_token\nrequestId = header x-request-id',
          ),
        ],
      ),
    );
  }

  Widget _field(String name, CodeController controller, String hint) => CodeBox(
    height: 150,
    child: CodeEditor(
      name: name,
      controller: controller,
      language: CodeLanguage.checks,
      hint: hint,
      hintLines: 3,
      variables: variables,
    ),
  );
}
