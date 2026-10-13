import 'package:flutter/material.dart';

import 'theme.dart';

/// The lines of [text] that hold something.
List<String> linesOf(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

/// The Tests tab: checks the response must pass, and values to keep from it
/// for later requests. Both are written one per line.
class TestsEditor extends StatelessWidget {
  const TestsEditor({super.key, required this.tests, required this.captures});

  final TextEditingController tests;
  final TextEditingController captures;

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
            const Key('tests'),
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
            const Key('captures'),
            captures,
            'token = body.access_token\nrequestId = header x-request-id',
          ),
        ],
      ),
    );
  }

  Widget _field(Key key, TextEditingController controller, String hint) =>
      TextField(
        key: key,
        controller: controller,
        minLines: 3,
        maxLines: 12,
        autocorrect: false,
        enableSuggestions: false,
        smartQuotesType: SmartQuotesType.disabled,
        smartDashesType: SmartDashesType.disabled,
        style: mono,
        decoration: InputDecoration(hintText: hint),
      );
}
