import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions.dart';
import 'src/rust/api/core.dart';
import 'theme.dart';

/// The response pane: status, timing, and the body and headers received.
class ResponseView extends StatelessWidget {
  const ResponseView({
    super.key,
    required this.sent,
    required this.error,
    required this.errorTitle,
    required this.sending,
    required this.sessionSize,
    required this.onExportSession,
  });

  /// How many exchanges the session holds, and how to export them all.
  final int sessionSize;
  final VoidCallback onExportSession;

  final Sent? sent;
  final String? error;

  /// What failed, in a few words, shown above [error].
  final String errorTitle;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final response = sent?.response;

    if (sending && response == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text(
              'Sending request…',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (error != null && !sending) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    errorTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(error!, key: const Key('error'), style: mono),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (response == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.send_outlined, size: 32, color: scheme.outlineVariant),
            const SizedBox(height: 12),
            Text(
              'Send a request to see the response',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (isDesktop) ...[
              const SizedBox(height: 4),
              Text(
                'Press $shortcutModifier↵ from anywhere',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ],
        ),
      );
    }

    // While a new request is in flight the previous response stays readable
    // but dimmed, so the pane does not blank out on every send.
    return Stack(
      children: [
        AnimatedOpacity(
          opacity: sending ? 0.45 : 1,
          duration: const Duration(milliseconds: 150),
          child: _Loaded(
            response: response,
            unresolved: sent?.unresolved ?? const [],
            tests: sent?.tests ?? const [],
            captured: sent?.captured ?? const [],
            captureProblems: sent?.captureProblems ?? const [],
            current: !sending,
            sessionSize: sessionSize,
            onExportSession: onExportSession,
          ),
        ),
        if (sending)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _Loaded extends StatelessWidget {
  const _Loaded({
    required this.response,
    required this.unresolved,
    required this.current,
    required this.sessionSize,
    required this.onExportSession,
    required this.tests,
    required this.captured,
    required this.captureProblems,
  });

  /// How the request's tests came out, and what it captured.
  final List<TestResult> tests;
  final List<Variable> captured;
  final List<String> captureProblems;

  final int sessionSize;
  final VoidCallback onExportSession;

  final Response response;
  final List<String> unresolved;

  /// False while this is the previous response and a new one is on its way.
  final bool current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = statusColor(response.status, scheme);
    final body = _prettyBody(response);
    final json = _asJson(response.body);
    final headers = [for (final h in response.headers) '${h.name}: ${h.value}']
        .join('\n');
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    final passed = tests.where((t) => t.passed).length;
    final hasTests =
        tests.isNotEmpty || captured.isNotEmpty || captureProblems.isNotEmpty;
    final testsFailed = passed < tests.length || captureProblems.isNotEmpty;

    return DefaultTabController(
      // Keyed, so the tabs are rebuilt when the Tests tab comes or goes.
      key: ValueKey(hasTests),
      length: hasTests ? 3 : 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Text(
                      '${response.status} ${response.statusText}',
                      // Only the response to the latest send carries the key.
                      key: current ? const Key('status') : null,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                _Fact(Icons.schedule, '${response.elapsedMs} ms', 'Time'),
                _Fact(Icons.data_usage, formatSize(response.sizeBytes), 'Size'),
                Text(response.httpVersion, style: muted),
                if (unresolved.isNotEmpty)
                  Tooltip(
                    message:
                        'These variables had no value and were sent as written',
                    child: Text(
                      'Unresolved: ${unresolved.join(', ')}',
                      key: const Key('unresolved'),
                      style: TextStyle(color: scheme.error, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
          // One rule under the tabs and the copy button alike.
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    dividerColor: Colors.transparent,
                    tabs: [
                      const Tab(height: 38, text: 'Body'),
                      Tab(
                        height: 38,
                        text: 'Headers (${response.headers.length})',
                      ),
                      if (hasTests)
                        Tab(
                          key: const Key('test-results-tab'),
                          height: 38,
                          child: Text(
                            tests.isEmpty
                                ? 'Tests'
                                : 'Tests ($passed/${tests.length})',
                            style: testsFailed
                                ? TextStyle(color: scheme.error)
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
                Builder(
                  builder: (context) => IconButton(
                    key: const Key('copy-response'),
                    tooltip: 'Copy',
                    iconSize: 18,
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () async {
                      // Whichever tab is showing is what gets copied.
                      final (text, what) = switch (DefaultTabController.of(
                        context,
                      ).index) {
                        0 => (body, 'Body'),
                        1 => (headers, 'Headers'),
                        _ => (
                          [
                            for (final t in tests)
                              t.passed
                                  ? 'pass  ${t.test}'
                                  : 'FAIL  ${t.test}  (${t.detail})',
                            for (final v in captured) '${v.key} = ${v.value}',
                            ...captureProblems,
                          ].join('\n'),
                          'Test results',
                        ),
                      };
                      await Clipboard.setData(ClipboardData(text: text));
                      if (!context.mounted) return;
                      showMessage(context, '$what copied');
                    },
                  ),
                ),
                PopupMenuButton<VoidCallback>(
                  key: const Key('export-response'),
                  tooltip: 'Export response',
                  iconSize: 18,
                  icon: const Icon(Icons.save_alt),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      key: const Key('export-json'),
                      // Only offered when the body really is JSON.
                      enabled: json != null,
                      value: () =>
                          saveTextFile(context, 'response.json', json ?? ''),
                      child: const Text('Save body as JSON…'),
                    ),
                    PopupMenuItem(
                      key: const Key('export-text'),
                      value: () =>
                          saveTextFile(context, 'response.txt', response.body),
                      child: const Text('Save body as text…'),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      key: const Key('export-har'),
                      value: onExportSession,
                      child: Text(
                        'Save session as HAR… ($sessionSize '
                        '${sessionSize == 1 ? 'request' : 'requests'})',
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                body.isEmpty
                    ? Center(
                        child: Text(
                          'The response has no body',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : _Body(text: body, json: _isJson(response)),
                _Headers(headers: response.headers),
                if (hasTests)
                  _Tests(
                    tests: tests,
                    captured: captured,
                    problems: captureProblems,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How each test came out, and the variables the response supplied.
class _Tests extends StatelessWidget {
  const _Tests({
    required this.tests,
    required this.captured,
    required this.problems,
  });

  final List<TestResult> tests;
  final List<Variable> captured;
  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pass = statusColor(200, scheme);
    final small = mono.copyWith(fontSize: 12.5);
    Widget line(IconData icon, Color color, String text, [String? note]) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: text, style: small),
                      if (note != null && note.isNotEmpty)
                        TextSpan(
                          text: '   $note',
                          style: small.copyWith(color: color),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
    return ListView(
      key: const Key('test-results'),
      padding: const EdgeInsets.all(12),
      children: [
        for (final test in tests)
          test.passed
              ? line(Icons.check_circle_outline, pass, test.test)
              : line(
                  Icons.cancel_outlined,
                  scheme.error,
                  test.test,
                  test.detail,
                ),
        if (captured.isNotEmpty || problems.isNotEmpty) ...[
          if (tests.isNotEmpty) const SizedBox(height: 8),
          Text('Captured', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          for (final variable in captured)
            line(
              Icons.bookmark_added_outlined,
              scheme.primary,
              '${variable.key} = ${variable.value}',
            ),
          for (final problem in problems)
            line(Icons.warning_amber_outlined, scheme.error, problem),
        ],
      ],
    );
  }
}

/// A small icon and value, such as the time a response took.
class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text, this.tooltip);

  final IconData icon;
  final String text;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.text, required this.json});

  final String text;
  final bool json;

  /// Colouring every token of a very large body would make scrolling slow.
  static const _highlightLimit = 200 * 1024;

  @override
  Widget build(BuildContext context) {
    final highlight = json && text.length <= _highlightLimit;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        width: double.infinity,
        child: highlight
            ? SelectableText.rich(
                TextSpan(
                  style: mono,
                  children: jsonSpans(text, Theme.of(context).brightness),
                ),
                key: const Key('responseBody'),
              )
            : SelectableText(text, key: const Key('responseBody'), style: mono),
      ),
    );
  }
}

class _Headers extends StatelessWidget {
  const _Headers({required this.headers});

  final List<Header> headers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SelectionArea(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: headers.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  headers[i].name,
                  style: mono.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(flex: 5, child: Text(headers[i].value, style: mono)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A byte count in the largest unit that keeps it readable.
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

bool _isJson(Response response) => response.headers.any(
  (h) =>
      h.name.toLowerCase() == 'content-type' &&
      h.value.toLowerCase().contains('json'),
);

/// [body] re-indented if it is valid JSON, whatever the server called it;
/// null otherwise.
String? _asJson(String body) {
  if (body.trim().isEmpty) return null;
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
  } catch (_) {
    return null;
  }
}

/// Re-indents JSON bodies; anything else is shown as received.
String _prettyBody(Response response) {
  if (!_isJson(response)) return response.body;
  try {
    return const JsonEncoder.withIndent('  ')
        .convert(jsonDecode(response.body));
  } catch (_) {
    return response.body;
  }
}

final _jsonToken = RegExp(
  r'"(?:[^"\\]|\\.)*"(\s*:)?|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:true|false|null)\b',
);

/// Colours keys, strings, numbers and literals in already-formatted JSON.
List<TextSpan> jsonSpans(String text, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final key = TextStyle(
    color: dark ? const Color(0xFF9CC4FF) : const Color(0xFF0B63C5),
  );
  final string = TextStyle(
    color: dark ? const Color(0xFF8FD6A4) : const Color(0xFF1A7F42),
  );
  final number = TextStyle(
    color: dark ? const Color(0xFFE5B454) : const Color(0xFF9A6700),
  );
  final literal = TextStyle(
    color: dark ? const Color(0xFFD0A8FF) : const Color(0xFF6E43C9),
  );

  final spans = <TextSpan>[];
  var at = 0;
  for (final match in _jsonToken.allMatches(text)) {
    if (match.start > at) {
      spans.add(TextSpan(text: text.substring(at, match.start)));
    }
    final token = match[0]!;
    if (token.startsWith('"')) {
      if (match[1] case final colon?) {
        // A key: colour the name, leave the colon plain.
        final name = token.substring(0, token.length - colon.length);
        spans
          ..add(TextSpan(text: name, style: key))
          ..add(TextSpan(text: colon));
      } else {
        spans.add(TextSpan(text: token, style: string));
      }
    } else {
      final isLiteral = token.startsWith(RegExp('[tfn]'));
      spans.add(TextSpan(text: token, style: isLiteral ? literal : number));
    }
    at = match.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}
