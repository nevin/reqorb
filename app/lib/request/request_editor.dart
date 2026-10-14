/// The tabs under the URL bar that hold the parts of a request.
library;

import 'package:flutter/material.dart';
import 'package:reqorb/shared/overflow_tab_bar.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/request/key_value_editor.dart';

typedef RequestBadges = ({
  int params,
  int headers,
  bool body,
  bool auth,
  int cookies,
  bool settings,
  int tests,
  bool scripts,
});

class RequestEditor extends StatelessWidget {
  const RequestEditor({
    super.key,
    required this.params,
    required this.headers,
    required this.tests,
    required this.scripts,
    required this.body,
    required this.auth,
    required this.cookies,
    required this.settings,
    required this.bulk,
    required this.onBulkChanged,
    required this.edits,
    required this.badges,
    this.message,
    this.variables = const [],
    this.section = 0,
    this.onSectionChanged,
  });

  /// The tab shown first, and word of the one moved to, so that each open
  /// request comes back to the part of it that was being worked on.
  final int section;
  final ValueChanged<int>? onSectionChanged;

  /// Names of the variables in reach, offered after `{{`.
  final List<String> variables;

  final CodeController params;
  final CodeController headers;
  final Widget body;
  final Widget auth;
  final Widget cookies;
  final Widget settings;
  final Widget tests;
  final Widget scripts;

  /// Names of the key-value tabs currently shown as text.
  final Set<String> bulk;
  final void Function(String name, bool bulk) onBulkChanged;

  /// Notifies when the request is edited, so the tab badges stay current.
  final Listenable edits;
  final RequestBadges Function() badges;

  /// Replaces the Body tab for requests that send messages instead.
  final Widget? message;

  /// Forms read better at a fixed measure than stretched across a wide pane.
  static Widget _form(Widget child) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: SizedBox.expand(child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 8,
      initialIndex: section,
      child: _SectionWatcher(
        onChanged: onSectionChanged,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListenableBuilder(
              listenable: edits,
              builder: (context, _) {
                final has = badges();
                return OverflowTabBar(
                  tabs: [
                    (
                      key: const Key('params-tab'),
                      label: TabLabel('Params', count: has.params),
                    ),
                    (
                      key: const Key('headers-tab'),
                      label: TabLabel('Headers', count: has.headers),
                    ),
                    (
                      key: const Key('body-tab'),
                      label: TabLabel(
                        message == null ? 'Body' : 'Message',
                        set: has.body,
                      ),
                    ),
                    (
                      key: const Key('auth-tab'),
                      label: TabLabel('Auth', set: has.auth),
                    ),
                    (
                      key: const Key('cookies-tab'),
                      label: TabLabel('Cookies', count: has.cookies),
                    ),
                    (
                      key: const Key('request-settings-tab'),
                      label: TabLabel('Settings', set: has.settings),
                    ),
                    (
                      key: const Key('tests-tab'),
                      label: TabLabel('Tests', count: has.tests),
                    ),
                    (
                      key: const Key('scripts-tab'),
                      label: TabLabel('Scripts', set: has.scripts),
                    ),
                  ],
                );
              },
            ),
            Expanded(
              child: TabBarView(
                children: [
                  KeyValueEditor(
                    controller: params,
                    name: 'params',
                    bulk: bulk.contains('params'),
                    onBulkChanged: (value) => onBulkChanged('params', value),
                    separator: ':',
                    bulkHint: 'page:1\nlimit:{{pageSize}}',
                    variables: variables,
                  ),
                  KeyValueEditor(
                    controller: headers,
                    name: 'headers',
                    bulk: bulk.contains('headers'),
                    onBulkChanged: (value) => onBulkChanged('headers', value),
                    bulkHint: 'Accept: application/json\nX-Request-Id: {{id}}',
                    variables: variables,
                  ),
                  message ?? body,
                  _form(auth),
                  cookies,
                  _form(settings),
                  _form(tests),
                  _form(scripts),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tab's name with a count, or a dot when the tab holds something that
/// cannot be counted, so filled tabs can be spotted without opening them.
class TabLabel extends StatelessWidget {
  const TabLabel(this.label, {super.key, this.count = 0, this.set = false});

  final String label;
  final int count;
  final bool set;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (count > 0) ...[
          const SizedBox(width: 5),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ] else if (set) ...[
          const SizedBox(width: 5),
          Icon(Icons.circle, size: 6, color: scheme.primary),
        ],
      ],
    );
  }
}

/// Reports the tab being shown, however it was reached.
class _SectionWatcher extends StatefulWidget {
  const _SectionWatcher({required this.onChanged, required this.child});

  final ValueChanged<int>? onChanged;
  final Widget child;

  @override
  State<_SectionWatcher> createState() => _SectionWatcherState();
}

class _SectionWatcherState extends State<_SectionWatcher> {
  TabController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = DefaultTabController.of(context);
    if (controller == _controller) return;
    _controller?.removeListener(_report);
    _controller = controller..addListener(_report);
  }

  void _report() => widget.onChanged?.call(_controller!.index);

  @override
  void dispose() {
    _controller?.removeListener(_report);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
