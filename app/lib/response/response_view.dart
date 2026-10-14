import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/response/sse.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/transfer/export_actions.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/shared/theme.dart';

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
    this.receiving = false,
    this.stopped = false,
  });

  /// Whether [sent] is a response still arriving, shown as far as it has.
  final bool receiving;

  /// Whether [sent] was cut short by stopping the send.
  final bool stopped;

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
          opacity: sending && !receiving ? 0.45 : 1,
          duration: const Duration(milliseconds: 150),
          child: _Loaded(
            response: response,
            unresolved: sent?.unresolved ?? const [],
            tests: sent?.tests ?? const [],
            captured: sent?.captured ?? const [],
            captureProblems: sent?.captureProblems ?? const [],
            graphqlErrors: sent?.graphqlErrors ?? const [],
            console: sent?.console ?? const [],
            url: sent?.exchanges.lastOrNull?.request.url,
            current: !sending,
            receiving: sending && receiving,
            stopped: stopped && !sending,
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

class _Loaded extends StatefulWidget {
  const _Loaded({
    required this.response,
    required this.unresolved,
    required this.current,
    required this.sessionSize,
    required this.onExportSession,
    required this.tests,
    required this.captured,
    required this.captureProblems,
    required this.graphqlErrors,
    required this.console,
    required this.receiving,
    required this.stopped,
    this.url,
  });

  /// Whether the response is still arriving.
  final bool receiving;

  /// Whether the response was cut short by stopping the send.
  final bool stopped;

  /// How the request's tests came out, and what it captured.
  final List<TestResult> tests;
  final List<Variable> captured;
  final List<String> captureProblems;

  /// What a GraphQL response says went wrong, whatever its status.
  final List<String> graphqlErrors;

  /// What the request's scripts printed.
  final List<String> console;

  final int sessionSize;
  final VoidCallback onExportSession;

  final Response response;
  final List<String> unresolved;

  /// Where the response came from, after any redirects; what a preview
  /// finds its pictures and styles relative to.
  final String? url;

  /// False while this is the previous response and a new one is on its way.
  final bool current;

  @override
  State<_Loaded> createState() => _LoadedState();
}

/// One tab of the response: what it is called, what it shows, and what
/// copying it copies.
typedef _Section = ({
  Tab tab,
  Widget view,
  String Function() copy,
  String what,
});

/// How the body is shown: re-indented and coloured, as received, or, for
/// a web page, as a browser would show it.
enum _BodyMode { pretty, raw, preview }

class _LoadedState extends State<_Loaded> {
  /// Kept from one response to the next, as is [_format].
  _BodyMode _mode = _BodyMode.pretty;

  /// What the body is read as; null to go by its type and how it looks.
  CodeLanguage? _format;

  /// Notified to open the search in the body.
  final _find = ValueNotifier(0);

  @override
  void dispose() {
    _find.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _Loaded(
      :response,
      :unresolved,
      :current,
      :sessionSize,
      :onExportSession,
      :tests,
      :captured,
      :captureProblems,
      :graphqlErrors,
      :console,
      :receiving,
      :stopped,
      :url,
    ) = widget;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = statusColor(response.status, scheme);
    final contentType = _contentType(response);
    final canPreview = previewsHtml && _isHtml(contentType, response.body);
    // A page kept from a response that had one falls back to Pretty.
    final mode = _mode == _BodyMode.preview && !canPreview
        ? _BodyMode.pretty
        : _mode;
    final raw = mode == _BodyMode.raw;
    final language = raw
        ? CodeLanguage.plain
        : _format ?? _languageOf(contentType, response.body);
    final body = raw || language != CodeLanguage.json
        ? response.body
        : _asJson(response.body) ?? response.body;
    final json = _asJson(response.body);
    final headers = [for (final h in response.headers) '${h.name}: ${h.value}']
        .join('\n');
    final cookies = [
      for (final h in response.headers)
        if (h.name.toLowerCase() == 'set-cookie') h.value,
    ];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    final passed = tests.where((t) => t.passed).length;
    final hasTests =
        tests.isNotEmpty ||
        captured.isNotEmpty ||
        captureProblems.isNotEmpty ||
        console.isNotEmpty;
    final testsFailed = passed < tests.length || captureProblems.isNotEmpty;

    // An event stream is read as its events first, and as text second.
    final hasEvents = contentType == 'text/event-stream';
    final events = hasEvents ? parseSse(response.body) : const <SseEvent>[];

    final Widget bodyView;
    if (response.bytes case final bytes?) {
      bodyView = _Binary(
        bytes: bytes,
        contentType: contentType,
        onSave: () => saveBytesFile(context, _binaryFileName(response), bytes),
      );
    } else if (body.isEmpty) {
      bodyView = Center(
        child: Text(
          receiving
              ? 'Receiving the response… '
                    '${formatSize(response.sizeBytes)} so far'
              : 'The response has no body',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    } else {
      bodyView = Column(
        children: [
          _BodyBar(
            mode: mode,
            canPreview: canPreview,
            onMode: (mode) => setState(() => _mode = mode),
            format: _format,
            onFormat: (format) => setState(() => _format = format),
            onFind: () => _find.value++,
          ),
          Expanded(
            child: mode == _BodyMode.preview
                ? _HtmlPreview(html: response.body, url: url)
                : CodeView(
                    name: 'responseBody',
                    text: body,
                    language: language,
                    findRequests: _find,
                    onLink: openLink,
                  ),
          ),
        ],
      );
    }

    final sections = <_Section>[
      if (hasEvents)
        (
          tab: Tab(
            key: const Key('events-tab'),
            height: 38,
            text: 'Events (${events.length})',
          ),
          view: EventsView(events: events, live: receiving),
          copy: () => response.body,
          what: 'Events',
        ),
      (
        tab: const Tab(height: 38, text: 'Body'),
        view: bodyView,
        copy: () => body,
        what: 'Body',
      ),
      (
        tab: Tab(
          key: const Key('cookies-tab'),
          height: 38,
          text: cookies.isEmpty ? 'Cookies' : 'Cookies (${cookies.length})',
        ),
        view: _Cookies(cookies: cookies),
        copy: () => cookies.join('\n'),
        what: 'Cookies',
      ),
      (
        tab: Tab(height: 38, text: 'Headers (${response.headers.length})'),
        view: _Headers(headers: response.headers),
        copy: () => headers,
        what: 'Headers',
      ),
      if (hasTests)
        (
          tab: Tab(
            key: const Key('test-results-tab'),
            height: 38,
            child: Text(
              tests.isEmpty ? 'Tests' : 'Tests ($passed/${tests.length})',
              style: testsFailed ? TextStyle(color: scheme.error) : null,
            ),
          ),
          view: _Tests(
            tests: tests,
            captured: captured,
            problems: captureProblems,
            console: console,
          ),
          copy: () => [
            for (final t in tests)
              t.passed ? 'pass  ${t.test}' : 'FAIL  ${t.test}  (${t.detail})',
            for (final v in captured) '${v.key} = ${v.value}',
            ...captureProblems,
          ].join('\n'),
          what: 'Test results',
        ),
    ];

    return DefaultTabController(
      // Keyed, so the tabs are rebuilt when one of them comes or goes.
      key: ValueKey((hasTests, hasEvents)),
      length: sections.length,
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
                _Fact(
                  Icons.storage_outlined,
                  formatSize(response.sizeBytes),
                  'Size',
                ),
                Text(response.httpVersion, style: muted),
                if (receiving)
                  Row(
                    key: const Key('receiving'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox.square(
                        dimension: 11,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                      const SizedBox(width: 6),
                      Text('Receiving…', style: muted),
                    ],
                  )
                else if (stopped)
                  Tooltip(
                    message: 'The send was stopped before the response ended',
                    child: Text(
                      'Stopped',
                      key: const Key('stopped'),
                      style: muted?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
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
          if (graphqlErrors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Column(
                    key: const Key('graphql-errors'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        graphqlErrors.length == 1
                            ? 'The query failed, though the status says '
                                  '${response.status}'
                            : '${graphqlErrors.length} errors, though the '
                                  'status says ${response.status}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onErrorContainer,
                        ),
                      ),
                      // The first few say enough; the body has them all.
                      for (final error in graphqlErrors.take(3))
                        Text(
                          error,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onErrorContainer,
                          ),
                        ),
                    ],
                  ),
                ),
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
                    tabs: [for (final s in sections) s.tab],
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
                      final section =
                          sections[DefaultTabController.of(context).index];
                      await Clipboard.setData(
                        ClipboardData(text: section.copy()),
                      );
                      if (!context.mounted) return;
                      showMessage(context, '${section.what} copied');
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
                    if (response.bytes case final bytes?)
                      PopupMenuItem(
                        key: const Key('export-file'),
                        value: () => saveBytesFile(
                          context,
                          _binaryFileName(response),
                          bytes,
                        ),
                        child: const Text('Save body as file…'),
                      )
                    else
                      PopupMenuItem(
                        key: const Key('export-text'),
                        value: () => saveTextFile(
                          context,
                          'response.txt',
                          response.body,
                        ),
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
            child: TabBarView(children: [for (final s in sections) s.view]),
          ),
        ],
      ),
    );
  }
}

/// Above the body: whether to show it as received, what to read it as,
/// and a way into the search.
class _BodyBar extends StatelessWidget {
  const _BodyBar({
    required this.mode,
    required this.canPreview,
    required this.onMode,
    required this.format,
    required this.onFormat,
    required this.onFind,
  });

  final _BodyMode mode;

  /// Whether the body is a page that can be shown as one.
  final bool canPreview;
  final ValueChanged<_BodyMode> onMode;
  final CodeLanguage? format;
  final ValueChanged<CodeLanguage?> onFormat;
  final VoidCallback onFind;

  static const _formats = {
    null: 'Auto',
    CodeLanguage.json: 'JSON',
    CodeLanguage.xml: 'XML / HTML',
    CodeLanguage.javascript: 'JavaScript',
    CodeLanguage.plain: 'Text',
  };

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.labelMedium;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
      child: Row(
        children: [
          SegmentedButton<_BodyMode>(
            key: const Key('body-mode'),
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity(horizontal: -3, vertical: -3),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: [
              ButtonSegment(
                value: _BodyMode.pretty,
                label: Text(
                  'Pretty',
                  key: const Key('body-pretty'),
                  style: small,
                ),
              ),
              ButtonSegment(
                value: _BodyMode.raw,
                label: Text('Raw', key: const Key('body-raw'), style: small),
              ),
              if (canPreview)
                ButtonSegment(
                  value: _BodyMode.preview,
                  label: Text(
                    'Preview',
                    key: const Key('body-preview'),
                    style: small,
                  ),
                ),
            ],
            selected: {mode},
            onSelectionChanged: (picked) => onMode(picked.first),
          ),
          const SizedBox(width: 8),
          // A body shown as received, or as a page, is not read as code.
          if (mode == _BodyMode.pretty)
            PopupMenuButton<CodeLanguage?>(
              key: const Key('body-format'),
              tooltip: 'Read the body as',
              initialValue: format,
              onSelected: onFormat,
              itemBuilder: (_) => [
                for (final MapEntry(:key, :value) in _formats.entries)
                  PopupMenuItem(value: key, child: Text(value)),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_formats[format]!, style: small),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
          const Spacer(),
          if (mode != _BodyMode.preview)
            IconButton(
              key: const Key('body-find'),
              tooltip: 'Find in the body ($shortcutModifier F)',
              iconSize: 18,
              icon: const Icon(Icons.search),
              onPressed: onFind,
            ),
        ],
      ),
    );
  }
}

/// Whether this platform can show a web page: macOS and iOS can, Windows
/// and Linux cannot.
bool get previewsHtml => WebViewPlatform.instance != null;

/// Whether a body of this type is a web page, or looks like one when
/// nobody said.
bool _isHtml(String contentType, String body) {
  if (contentType.contains('html')) return true;
  if (contentType.isNotEmpty) return false;
  final start = body.trimLeft().toLowerCase();
  return start.startsWith('<!doctype html') || start.startsWith('<html');
}

/// Opens a web address from a response in the browser.
Future<void> openLink(Uri uri) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// An HTML body shown as a page. It cannot run scripts or go anywhere
/// else, since it came from a server that may not be trusted; it may still
/// fetch its pictures and styles.
class _HtmlPreview extends StatefulWidget {
  const _HtmlPreview({required this.html, required this.url});

  final String html;
  final String? url;

  @override
  State<_HtmlPreview> createState() => _HtmlPreviewState();
}

class _HtmlPreviewState extends State<_HtmlPreview> {
  /// True from asking for the page until it has loaded: the one
  /// navigation allowed.
  bool _loading = false;

  late final _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.disabled)
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          // Frames inside the page load as the page says.
          if (!request.isMainFrame) return NavigationDecision.navigate;
          if (!_loading) return NavigationDecision.prevent;
          _loading = false;
          return NavigationDecision.navigate;
        },
        onPageFinished: (_) => _loading = false,
      ),
    );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_HtmlPreview old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html || old.url != widget.url) _load();
  }

  void _load() {
    _loading = true;
    _web.loadHtmlString(widget.html, baseUrl: widget.url);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: WebViewWidget(key: const Key('body-preview-page'), controller: _web),
  );
}

/// The cookies the response set, one to a row with their attributes.
class _Cookies extends StatelessWidget {
  const _Cookies({required this.cookies});

  /// Each `Set-Cookie` header's value.
  final List<String> cookies;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (cookies.isEmpty) {
      return Center(
        child: Text(
          'The response set no cookies',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final small = mono.copyWith(fontSize: 12, color: scheme.onSurfaceVariant);
    return SelectionArea(
      child: ListView.separated(
        key: const Key('response-cookies'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: cookies.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
        itemBuilder: (context, i) {
          final (:name, :value, :attributes) = parseSetCookie(cookies[i]);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Text(
                    name,
                    style: mono.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(value, style: mono),
                      if (attributes.isNotEmpty)
                        Text(attributes.join(' · '), style: small),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A `Set-Cookie` value split into the cookie and what is said about it,
/// such as `Path=/` and `HttpOnly`.
({String name, String value, List<String> attributes}) parseSetCookie(
  String header,
) {
  final parts = header.split(';').map((p) => p.trim()).toList();
  final pair = parts.first;
  final equals = pair.indexOf('=');
  return (
    name: equals < 0 ? '' : pair.substring(0, equals).trim(),
    value: equals < 0 ? pair : pair.substring(equals + 1).trim(),
    attributes: [
      for (final p in parts.skip(1))
        if (p.isNotEmpty) p,
    ],
  );
}

/// How each test came out, and the variables the response supplied.
class _Tests extends StatelessWidget {
  const _Tests({
    required this.tests,
    required this.captured,
    required this.problems,
    required this.console,
  });

  /// What the scripts printed, oldest first.
  final List<String> console;
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
        if (console.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Console', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          for (final (i, printed) in console.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SelectableText(
                printed,
                key: Key('console-$i'),
                style: small.copyWith(
                  color: printed.startsWith('error: ')
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

String _contentType(Response response) {
  for (final h in response.headers) {
    if (h.name.toLowerCase() == 'content-type') {
      return h.value.split(';').first.trim().toLowerCase();
    }
  }
  return '';
}

/// A file name for a binary body, with an extension taken from its type.
String _binaryFileName(Response response) {
  final type = _contentType(response);
  final subtype = type.contains('/') ? type.split('/').last : '';
  final extension = switch (subtype) {
    'jpeg' => 'jpg',
    'svg+xml' => 'svg',
    'x-icon' || 'vnd.microsoft.icon' => 'ico',
    'octet-stream' || '' => 'bin',
    _ => subtype.replaceAll(RegExp(r'[^a-z0-9]'), ''),
  };
  return 'response.${extension.isEmpty ? 'bin' : extension}';
}

/// A body that is not text: shown if it is an image, and saved as it is.
class _Binary extends StatelessWidget {
  const _Binary({
    required this.bytes,
    required this.contentType,
    required this.onSave,
  });

  final Uint8List bytes;
  final String contentType;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final about = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.insert_drive_file_outlined,
          size: 32,
          color: scheme.outlineVariant,
        ),
        const SizedBox(height: 10),
        Text(
          '${contentType.isEmpty ? 'Binary' : contentType} · '
          '${formatSize(bytes.length)}',
          key: const Key('binary-body'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('binary-save'),
          icon: const Icon(Icons.save_alt, size: 18),
          label: const Text('Save to file…'),
          onPressed: onSave,
        ),
      ],
    );
    if (!contentType.startsWith('image/')) return Center(child: about);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Image.memory(
              bytes,
              fit: BoxFit.scaleDown,
              // A format the platform cannot decode is still a file to save.
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 8),
          about,
        ],
      ),
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

/// [body] re-indented if it is valid JSON, whatever the server called it;
/// null otherwise.
String? _asJson(String body) {
  if (body.trim().isEmpty) return null;
  try {
    return JsonEncoder.withIndent(CodeStyle.indent).convert(jsonDecode(body));
  } catch (_) {
    return null;
  }
}

/// The language of a body: as the server labelled it, otherwise as it
/// looks.
CodeLanguage _languageOf(String contentType, String body) {
  final named = CodeLanguage.ofContentType(contentType);
  return named == CodeLanguage.plain ? CodeLanguage.sniff(body) : named;
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
