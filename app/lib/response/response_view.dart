import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/document/memory_document.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/document_view.dart';
import 'package:reqorb/editor/hex_view.dart';
import 'package:reqorb/editor/json_tree_view.dart';
import 'package:reqorb/files/file_page.dart';
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

  /// What to copy; null when it cannot be, having said why.
  FutureOr<String?> Function() copy,
  String what,
});

/// How the body is shown: re-indented and coloured, as received, or, for
/// a web page, as a browser would show it.
enum _BodyMode { pretty, raw, tree, preview }

class _LoadedState extends State<_Loaded> {
  /// Kept from one response to the next, as is [_format].
  _BodyMode _mode = _BodyMode.pretty;

  /// What the body is read as; null to go by its type and how it looks.
  CodeLanguage? _format;

  /// The body last re-indented, and what came of it: worked out once per
  /// body rather than on every build, and apart from the screen when it
  /// is long, as at ten megabytes that takes a second.
  String? _indented;
  String? _indentedJson;
  int _indents = 0;

  /// [body] re-indented if it is JSON; null if not, or until a long one
  /// has been, when the page is built again.
  String? _jsonOf(String body) {
    if (body == _indented) return _indentedJson;
    _indented = body;
    _indentedJson = null;
    if (body.length <= _indentApartOver) {
      return _indentedJson = _asJson(body);
    }
    final indent = ++_indents;
    _asJsonApart(body).then((json) {
      if (!mounted || indent != _indents) return;
      setState(() => _indentedJson = json);
    });
    return null;
  }

  static const _indentApartOver = 256 * 1024;

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
    // A body too big to hold is in a file, with only its start here.
    final spilled = response.bodyFile;
    final isHtml = spilled == null && _isHtml(contentType, response.body);
    final canPreview = previewsHtml && isHtml;
    final json = spilled == null ? _jsonOf(response.body) : null;
    // JSON can be explored as a tree, however big.
    final canTree =
        json != null ||
        (spilled != null &&
            (_format ?? _languageOf(contentType, response.body)) ==
                CodeLanguage.json);
    // A page or a tree kept from a response that had one falls back to
    // Pretty.
    final mode =
        (_mode == _BodyMode.preview && !canPreview) ||
            (_mode == _BodyMode.tree && !canTree)
        ? _BodyMode.pretty
        : _mode;
    final raw = mode == _BodyMode.raw;
    final language = raw
        ? CodeLanguage.plain
        : _format ?? _languageOf(contentType, response.body);
    final body = raw || language != CodeLanguage.json
        ? response.body
        : json ?? response.body;
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

    Widget bar() => _BodyBar(
      mode: mode,
      canPreview: canPreview,
      canTree: canTree,
      onMode: (mode) => setState(() => _mode = mode),
      format: _format,
      onFormat: (format) => setState(() => _format = format),
      // Where the page cannot be shown here, a browser shows it.
      onOpenInBrowser: isHtml && !previewsHtml
          ? () => _openInBrowser(context, response.body, url)
          : null,
    );
    final Widget bodyView;
    if (spilled != null) {
      final file = _FileBody(
        key: ValueKey(spilled),
        path: spilled,
        size: response.sizeBytes,
        contentType: contentType,
        text: response.body.isNotEmpty,
        language: raw ? CodeLanguage.plain : language,
        mode: mode,
      );
      bodyView = response.body.isEmpty
          ? file
          : Column(
              children: [
                bar(),
                Expanded(child: file),
              ],
            );
    } else if (response.bytes case final bytes?) {
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
          bar(),
          Expanded(
            child: mode == _BodyMode.preview
                ? _HtmlPreview(html: response.body, url: url)
                : mode == _BodyMode.tree
                ? _TreeBody(key: ValueKey(response.body), text: response.body)
                : CodeView(
                    name: 'responseBody',
                    text: body,
                    language: language,
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
        copy: spilled == null
            ? () => body
            : () => _readForCopy(context, spilled),
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
                      final text = await section.copy();
                      if (text == null) return;
                      await Clipboard.setData(ClipboardData(text: text));
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
                    if (spilled != null)
                      PopupMenuItem(
                        key: const Key('export-file'),
                        value: () => saveCopyOf(
                          context,
                          spilled,
                          response.body.isEmpty
                              ? _binaryFileName(response)
                              : 'response.txt',
                        ),
                        child: const Text('Save body as file…'),
                      )
                    else if (response.bytes case final bytes?)
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

/// Above the body: whether to show it as received or as a page, and what
/// to read it as.
class _BodyBar extends StatelessWidget {
  const _BodyBar({
    required this.mode,
    required this.canPreview,
    required this.canTree,
    required this.onMode,
    required this.format,
    required this.onFormat,
    this.onOpenInBrowser,
  });

  /// Whether the body is JSON, which can be explored as a tree.
  final bool canTree;

  /// Shows the page in the browser; null where it is not offered.
  final VoidCallback? onOpenInBrowser;

  final _BodyMode mode;

  /// Whether the body is a page that can be shown as one.
  final bool canPreview;
  final ValueChanged<_BodyMode> onMode;
  final CodeLanguage? format;
  final ValueChanged<CodeLanguage?> onFormat;

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
              if (canTree)
                ButtonSegment(
                  value: _BodyMode.tree,
                  label: Text(
                    'Tree',
                    key: const Key('body-tree'),
                    style: small,
                  ),
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
          if (onOpenInBrowser case final open?)
            IconButton(
              key: const Key('body-open-browser'),
              tooltip: 'Open the page in the browser',
              iconSize: 18,
              icon: const Icon(Icons.open_in_browser),
              onPressed: open,
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

/// Writes an HTML body to a file and opens it in the browser.
Future<void> _openInBrowser(
  BuildContext context,
  String html,
  String? url,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final folder = await getTemporaryDirectory();
    final file = File(
      '${folder.path}${Platform.pathSeparator}'
      'reqorb-preview-${DateTime.now().millisecondsSinceEpoch}.html',
    );
    await file.writeAsString(pageForBrowser(html, url));
    if (!await launchUrl(Uri.file(file.path))) {
      throw const FileSystemException('no browser took the page');
    }
  } catch (error) {
    notify(messenger, 'Could not open the page: $error');
  }
}

/// [html] made safe to open in a browser: scripts and plugins are
/// blocked, as they are in the preview, and pictures and styles are found
/// relative to [url], where the page came from.
String pageForBrowser(String html, String? url) {
  final guard = [
    '<meta http-equiv="Content-Security-Policy" '
        'content="script-src \'none\'; object-src \'none\'">',
    if (url != null)
      '<base href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(url)}">',
  ].join();
  // After the doctype, if there is one, so the page keeps its mode; the
  // browser moves what comes before <html> into the head.
  final doctype = RegExp(r'^\s*<!doctype[^>]*>', caseSensitive: false);
  if (doctype.firstMatch(html) case final match?) {
    return html.replaceRange(match.end, match.end, guard);
  }
  return guard + html;
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
class _Binary extends StatefulWidget {
  const _Binary({
    required this.bytes,
    required this.contentType,
    required this.onSave,
  });

  final Uint8List bytes;
  final String contentType;
  final VoidCallback onSave;

  @override
  State<_Binary> createState() => _BinaryState();
}

class _BinaryState extends State<_Binary> {
  /// Whether the bytes themselves are shown, in hexadecimal.
  bool _hex = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final contentType = widget.contentType;
    final image = contentType.startsWith('image/');
    final about = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_hex) ...[
          Icon(
            Icons.insert_drive_file_outlined,
            size: 32,
            color: scheme.outlineVariant,
          ),
          const SizedBox(height: 10),
        ],
        Text(
          '${contentType.isEmpty ? 'Binary' : contentType} · '
          '${formatSize(widget.bytes.length)}',
          key: const Key('binary-body'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('binary-save'),
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Save to file…'),
              onPressed: widget.onSave,
            ),
            OutlinedButton.icon(
              key: const Key('binary-hex'),
              icon: Icon(_hex ? Icons.image_outlined : Icons.memory, size: 18),
              label: Text(
                _hex
                    ? (image ? 'Show the image' : 'Hide the bytes')
                    : 'Show the bytes',
              ),
              onPressed: () => setState(() => _hex = !_hex),
            ),
          ],
        ),
      ],
    );
    if (_hex) {
      return Column(
        children: [
          Padding(padding: const EdgeInsets.only(top: 8), child: about),
          Expanded(child: _HexBody(bytes: widget.bytes)),
        ],
      );
    }
    if (!image) return Center(child: about);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Image.memory(
              widget.bytes,
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

/// Reads a body kept in a file to copy it, if it is not too big to.
Future<String?> _readForCopy(BuildContext context, String path) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final size = await File(path).length();
    if (size > copyLimit) {
      notify(
        messenger,
        'The body is ${formatSize(size)}; at most '
        '${formatSize(copyLimit)} can be copied. Save it as a file instead.',
      );
      return null;
    }
    return utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
  } catch (e) {
    notify(messenger, 'Could not read the body: $e');
    return null;
  }
}

/// A body too big to hold, shown from the file it was written to as it
/// arrived: text in a [DocumentView], read a screenful at a time, JSON
/// re-indented into another file for Pretty or explored as a tree, and
/// anything else in hexadecimal.
class _FileBody extends StatefulWidget {
  const _FileBody({
    super.key,
    required this.path,
    required this.size,
    required this.contentType,
    required this.text,
    required this.language,
    required this.mode,
  });

  final String path;
  final int size;
  final String contentType;

  /// Whether the body is text, rather than an image or other binary.
  final bool text;
  final CodeLanguage language;
  final _BodyMode mode;

  @override
  State<_FileBody> createState() => _FileBodyState();
}

class _FileBodyState extends State<_FileBody> {
  TextDocument? _document;
  String? _error;
  bool _asked = false;

  /// The JSON re-indented, once it has been, and how far that has got.
  TextDocument? _pretty;
  StreamSubscription<DocFormatUpdate>? _indenting;
  double? _indented;
  String? _notJson;

  bool get _wantsPretty =>
      widget.mode == _BodyMode.pretty && widget.language == CodeLanguage.json;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    _open(widget.path).then(
      (document) {
        if (!mounted) return document.dispose();
        setState(() => _document = document);
        _indentIfWanted();
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = '$e');
      },
    );
  }

  @override
  void didUpdateWidget(_FileBody old) {
    super.didUpdateWidget(old);
    _indentIfWanted();
  }

  Future<TextDocument> _open(String path) {
    final engine = Engine.maybeOf(context);
    return engine == null
        ? MemoryDocument.open(path)
        : engine.openDocument(path);
  }

  /// Starts re-indenting the JSON for Pretty, the first time it is shown.
  void _indentIfWanted() {
    final document = _document;
    if (!_wantsPretty || document == null) return;
    if (_pretty != null || _indenting != null || _notJson != null) return;
    _indented = 0;
    _indenting = document.formatJson(indent: CodeStyle.indent).listen((u) {
      if (!mounted) return;
      if (!u.done) {
        setState(() => _indented = u.total == 0 ? null : u.read / u.total);
        return;
      }
      final path = u.path;
      if (path == null) {
        setState(() => _notJson = u.error ?? 'not valid JSON');
        return;
      }
      _open(path).then((pretty) {
        if (!mounted) return pretty.dispose();
        setState(() => _pretty = pretty);
      });
    });
  }

  @override
  void dispose() {
    _indenting?.cancel();
    _document?.dispose();
    _pretty?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final kind = widget.contentType.isEmpty ? 'Binary' : widget.contentType;
    final document = _document;
    final Widget shown;
    if (document == null) {
      shown = Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Text(_error!, style: muted),
      );
    } else if (!widget.text) {
      shown = HexView(document: document, name: 'responseHex');
    } else if (widget.mode == _BodyMode.tree) {
      shown = JsonTreeView(document: document, name: 'responseTree');
    } else if (_wantsPretty && _notJson == null) {
      final pretty = _pretty;
      shown = pretty != null
          ? DocumentView(
              key: const ValueKey('pretty'),
              name: 'responseBody-document',
              document: pretty,
              language: CodeLanguage.json,
            )
          : Center(
              child: SizedBox(
                width: 240,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      key: const Key('response-indenting'),
                      value: _indented,
                    ),
                    const SizedBox(height: 8),
                    Text('Indenting the JSON…', style: muted),
                  ],
                ),
              ),
            );
    } else {
      shown = DocumentView(
        key: const ValueKey('raw'),
        name: 'responseBody-document',
        document: document,
        language: widget.language,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.text
                      ? _notJson != null && _wantsPretty
                            ? 'Shown as received: $_notJson'
                            : '${formatSize(widget.size)}, too big to hold in '
                                  'memory, so it is read from a file as it is '
                                  'shown.'
                      : '$kind · ${formatSize(widget.size)}',
                  key: Key(widget.text ? 'response-from-file' : 'binary-body'),
                  style: muted,
                ),
              ),
              if (widget.text)
                TextButton.icon(
                  key: const Key('response-open-file'),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open to edit'),
                  onPressed: () => showFile(
                    context,
                    widget.path,
                    temporary: true,
                    name: 'Response body',
                  ),
                )
              else
                TextButton.icon(
                  key: const Key('binary-save'),
                  icon: const Icon(Icons.save_alt, size: 16),
                  label: const Text('Save to file…'),
                  onPressed: () => saveCopyOf(context, widget.path, 'response'),
                ),
            ],
          ),
        ),
        Expanded(child: shown),
      ],
    );
  }
}

/// A JSON body held in memory, explored as a tree.
class _TreeBody extends StatefulWidget {
  const _TreeBody({super.key, required this.text});

  final String text;

  @override
  State<_TreeBody> createState() => _TreeBodyState();
}

class _TreeBodyState extends State<_TreeBody> {
  TextDocument? _document;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _document ??=
        Engine.maybeOf(context)?.documentOf(widget.text) ??
        MemoryDocument(widget.text);
  }

  @override
  void dispose() {
    _document?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      JsonTreeView(document: _document!, name: 'responseTree');
}

/// Binary bytes held in memory, in hexadecimal.
class _HexBody extends StatefulWidget {
  const _HexBody({required this.bytes});

  final Uint8List bytes;

  @override
  State<_HexBody> createState() => _HexBodyState();
}

class _HexBodyState extends State<_HexBody> {
  TextDocument? _document;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _document ??=
        Engine.maybeOf(context)?.documentOfBytes(widget.bytes) ??
        MemoryDocument.bytes(widget.bytes);
  }

  @override
  void dispose() {
    _document?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      HexView(document: _document!, name: 'responseHex');
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

/// [_asJson] on another isolate. Made here, out of the state, so that the
/// closure sent there holds only the body.
Future<String?> _asJsonApart(String body) => Isolate.run(() => _asJson(body));

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
