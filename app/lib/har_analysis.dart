import 'dart:convert';

import 'package:flutter/material.dart';

import 'response_view.dart';
import 'src/rust/api/core.dart';
import 'theme.dart';

/// `1.25 s` or `340 ms`.
String formatDuration(int ms) =>
    ms >= 1000 ? '${(ms / 1000).toStringAsFixed(2)} s' : '$ms ms';

enum _Sort {
  order('In order'),
  slowest('Slowest first'),
  largest('Largest first');

  const _Sort(this.label);
  final String label;
}

/// A report on a HAR archive: totals, findings, breakdowns and every
/// request on a timeline.
class HarAnalysisPage extends StatefulWidget {
  const HarAnalysisPage({
    super.key,
    required this.name,
    required this.report,
    required this.onImport,
  });

  /// What was analysed: a file name, or the session.
  final String name;
  final HarReport report;

  /// Imports the requests at these positions in the archive as a collection.
  final Future<void> Function(BuildContext context, List<int> entries) onImport;

  @override
  State<HarAnalysisPage> createState() => _HarAnalysisPageState();
}

class _HarAnalysisPageState extends State<HarAnalysisPage> {
  /// The finding whose requests the table is narrowed to, if any.
  HarFinding? _finding;
  _Sort _sort = _Sort.order;

  /// The heading of the request table.
  final _requests = GlobalKey();

  /// Text the listed requests must contain.
  final _search = TextEditingController();

  /// Positions of the requests to import; all of them to begin with.
  late final _selected = {for (var i = 0; i < _report.entries.length; i++) i};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Ticks or clears every request listed, leaving the hidden ones alone.
  void _selectShown(List<int> rows, bool select) => setState(
    () => select ? _selected.addAll(rows) : _selected.removeAll(rows),
  );

  /// Narrows the table to [finding]'s requests and brings it into view, or
  /// shows every request again when that finding is already chosen.
  void _toggle(HarFinding finding) {
    final chosen = !identical(_finding, finding);
    setState(() => _finding = chosen ? finding : null);
    if (!chosen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final heading = _requests.currentContext;
      if (heading == null) return;
      Scrollable.ensureVisible(
        heading,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  HarReport get _report => widget.report;

  /// Indexes of the entries to list, filtered and sorted.
  List<int> get _rows {
    final entries = _report.entries;
    final words = _search.text.toLowerCase().split(' ')
      ..removeWhere((w) => w.isEmpty);
    bool matches(int i) {
      final e = entries[i];
      final text = '${e.method} ${e.url} ${e.status} ${e.kind}'.toLowerCase();
      return words.every(text.contains);
    }

    final rows = [
      for (final i
          in _finding?.entries ?? [for (var i = 0; i < entries.length; i++) i])
        if (matches(i)) i,
    ];
    switch (_sort) {
      case _Sort.order:
        rows.sort();
      case _Sort.slowest:
        rows.sort((a, b) => entries[b].timeMs.compareTo(entries[a].timeMs));
      case _Sort.largest:
        rows.sort(
          (a, b) => entries[b].sizeBytes.compareTo(entries[a].sizeBytes),
        );
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = _report;
    final rows = _rows;
    final heading = theme.textTheme.titleSmall;
    final chosen = (_selected.toList()..sort());
    final shownChosen = rows.where(_selected.contains).length;
    return Scaffold(
      appBar: AppBar(
        title: Text('HAR analysis · ${widget.name}'),
        actions: [
          TextButton.icon(
            key: const Key('har-import'),
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: Text(
              chosen.length == report.entries.length
                  ? 'Import as collection'
                  : 'Import ${chosen.length} as collection',
            ),
            onPressed: chosen.isEmpty
                ? null
                : () => widget.onImport(context, chosen),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // The timeline needs room; a narrow window keeps the numbers.
          final timeline = constraints.maxWidth >= 760;
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                // Built whole, so the table's heading can be scrolled to.
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _summary(theme),
                      const SizedBox(height: 20),
                      Text('Findings', style: heading),
                      const SizedBox(height: 8),
                      if (report.findings.isEmpty)
                        Text(
                          report.entries.isEmpty
                              ? 'This archive holds no requests.'
                              : 'Nothing stands out: no failures, slow or '
                                    'oversized responses, or exposed credentials.',
                          key: const Key('har-no-findings'),
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      for (var i = 0; i < report.findings.length; i++)
                        _findingTile(theme, i),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 24,
                        runSpacing: 16,
                        children: [
                          _breakdown(theme, 'Status', report.statuses),
                          _breakdown(theme, 'Hosts', report.hosts),
                          _breakdown(theme, 'Content', report.kinds),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Row(
                        key: _requests,
                        children: [
                          Text('Requests', style: heading),
                          const SizedBox(width: 12),
                          if (_finding != null)
                            Flexible(
                              child: InputChip(
                                key: const Key('har-filter'),
                                label: Text(
                                  '${rows.length} of ${report.entries.length} · '
                                  '${_finding!.title}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                                visualDensity: VisualDensity.compact,
                                onDeleted: () =>
                                    setState(() => _finding = null),
                                deleteButtonTooltipMessage: 'Show all requests',
                              ),
                            ),
                          const Spacer(),
                          DropdownButton<_Sort>(
                            key: const Key('har-sort'),
                            value: _sort,
                            isDense: true,
                            underline: const SizedBox.shrink(),
                            style: theme.textTheme.bodySmall,
                            items: [
                              for (final sort in _Sort.values)
                                DropdownMenuItem(
                                  value: sort,
                                  child: Text(sort.label),
                                ),
                            ],
                            onChanged: (sort) =>
                                setState(() => _sort = sort ?? _Sort.order),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Checkbox(
                            key: const Key('har-select-shown'),
                            tristate: true,
                            value: shownChosen == 0
                                ? false
                                : shownChosen == rows.length
                                ? true
                                : null,
                            onChanged: rows.isEmpty
                                ? null
                                : (_) => _selectShown(
                                    rows,
                                    shownChosen < rows.length,
                                  ),
                          ),
                          Text(
                            '${chosen.length} of ${report.entries.length} '
                            'selected to import',
                            key: const Key('har-selected'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 320,
                                ),
                                child: TextField(
                                  key: const Key('har-search'),
                                  controller: _search,
                                  autocorrect: false,
                                  style: theme.textTheme.bodySmall,
                                  decoration: const InputDecoration(
                                    hintText:
                                        'Filter: address, method, 404, json…',
                                    prefixIcon: Icon(Icons.search, size: 16),
                                    prefixIconConstraints: BoxConstraints(
                                      minWidth: 32,
                                    ),
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 12),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final index = rows[i];
                    final entry = report.entries[index];
                    return _EntryRow(
                      key: Key('har-entry-$index'),
                      index: index,
                      entry: entry,
                      spanMs: report.spanMs,
                      timeline: timeline,
                      selected: _selected.contains(index),
                      onSelected: (select) => setState(
                        () => select
                            ? _selected.add(index)
                            : _selected.remove(index),
                      ),
                      onOpen: () => showDialog<void>(
                        context: context,
                        builder: (_) => _EntryDialog(entry: entry),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _summary(ThemeData theme) {
    final report = _report;
    final scheme = theme.colorScheme;
    return Wrap(
      key: const Key('har-summary'),
      spacing: 12,
      runSpacing: 12,
      children: [
        _Stat(label: 'Requests', value: '${report.entries.length}'),
        _Stat(
          label: 'Failed',
          value: '${report.failed}',
          color: report.failed > 0 ? scheme.error : null,
        ),
        _Stat(label: 'Transferred', value: formatSize(report.totalBytes)),
        _Stat(
          label: 'First to last',
          value: formatDuration(report.spanMs),
          hint: 'From the start of the first request to the end of the last',
        ),
        _Stat(
          label: 'Time added up',
          value: formatDuration(report.totalTimeMs),
          hint: 'Every request\'s time added together',
        ),
        if (report.creator.isNotEmpty)
          _Stat(label: 'Recorded by', value: report.creator),
      ],
    );
  }

  Widget _findingTile(ThemeData theme, int index) {
    final scheme = theme.colorScheme;
    final finding = _report.findings[index];
    final (icon, color) = switch (finding.severity) {
      HarSeverity.error => (Icons.error_outline, scheme.error),
      HarSeverity.warning => (
        Icons.warning_amber_outlined,
        methodColor('POST', scheme.brightness),
      ),
      HarSeverity.info => (Icons.info_outline, scheme.onSurfaceVariant),
    };
    final selected = identical(_finding, finding);
    // The first line is the advice; the rest name the requests.
    final lines = finding.detail.split('\n');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: Key('har-finding-$index'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _toggle(finding),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(finding.title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        lines.first,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (lines.length > 1) ...[
                        const SizedBox(height: 6),
                        Text(
                          lines.skip(1).join('\n'),
                          style: mono.copyWith(fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected ? Icons.filter_alt : Icons.filter_alt_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _breakdown(ThemeData theme, String title, List<HarCount> counts) {
    const shown = 6;
    final scheme = theme.colorScheme;
    final total = _report.entries.length;
    final small = theme.textTheme.bodySmall;
    return SizedBox(
      width: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final count in counts.take(shown))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          count.name.isEmpty ? '(none)' : count.name,
                          style: small,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${count.count} · ${formatSize(count.bytes)} · '
                        '${formatDuration(count.timeMs)}',
                        style: small?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  LinearProgressIndicator(
                    value: total == 0 ? 0 : count.count / total,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ],
              ),
            ),
          if (counts.length > shown)
            Text(
              'and ${counts.length - shown} more',
              style: small?.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.color,
    this.hint,
  });

  final String label;
  final String value;
  final Color? color;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tile = Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    return hint == null ? tile : Tooltip(message: hint, child: tile);
  }
}

/// One request: what it was, how it ended, and where it sat in time.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.index,
    required this.entry,
    required this.spanMs,
    required this.timeline,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
  });

  final int index;
  final HarEntry entry;
  final int spanMs;
  final bool timeline;

  /// Whether the request is ticked for import.
  final bool selected;
  final ValueChanged<bool> onSelected;

  /// Shows the request in full.
  final VoidCallback onOpen;

  /// The address without its scheme and host, which have their own column.
  String get _path {
    final rest = entry.url.contains('://')
        ? entry.url.substring(entry.url.indexOf('://') + 3)
        : entry.url;
    final slash = rest.indexOf('/');
    return slash < 0 ? '/' : rest.substring(slash);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = entry.status == 0 || entry.status >= 400;
    final color = failed ? scheme.error : statusColor(entry.status, scheme);
    final small = mono.copyWith(fontSize: 12);
    final muted = small.copyWith(color: scheme.onSurfaceVariant);
    return InkWell(
      onTap: onOpen,
      child: Row(
        children: [
          Checkbox(
            key: Key('har-check-$index'),
            value: selected,
            visualDensity: VisualDensity.compact,
            onChanged: (value) => onSelected(value ?? false),
          ),
          SizedBox(
            width: 36,
            child: Text(
              entry.status == 0 ? '—' : '${entry.status}',
              style: small.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: 58,
            child: Text(
              entry.method,
              overflow: TextOverflow.ellipsis,
              style: small.copyWith(
                color: methodColor(entry.method, scheme.brightness),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Tooltip(
              message: entry.url,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: _path, style: small),
                    TextSpan(text: '  ${entry.host}', style: muted),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          SizedBox(width: 52, child: Text(entry.kind, style: muted)),
          SizedBox(
            width: 72,
            child: Text(
              formatSize(entry.sizeBytes),
              textAlign: TextAlign.right,
              style: small,
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(
              formatDuration(entry.timeMs),
              textAlign: TextAlign.right,
              style: small,
            ),
          ),
          if (timeline) ...[
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Tooltip(
                message:
                    'Started at ${formatDuration(entry.offsetMs)}'
                    '${entry.waitMs == null ? '' : ', waited ${formatDuration(entry.waitMs!)} for the first byte'}',
                child: LayoutBuilder(
                  builder: (context, box) {
                    final scale = spanMs <= 0 ? 0.0 : box.maxWidth / spanMs;
                    final width = (entry.timeMs * scale).clamp(
                      2.0,
                      box.maxWidth,
                    );
                    final left = (entry.offsetMs * scale).clamp(
                      0.0,
                      box.maxWidth - width,
                    );
                    return Container(
                      height: 10,
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Container(
                        margin: EdgeInsets.only(left: left),
                        width: width,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Everything the archive recorded about one request.
class _EntryDialog extends StatelessWidget {
  const _EntryDialog({required this.entry});

  final HarEntry entry;

  /// [body] indented when it is JSON, otherwise as recorded.
  static String _readable(String body) {
    final trimmed = body.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return body;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
    } on FormatException {
      return body;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = entry.status == 0 || entry.status >= 400;
    final color = failed ? scheme.error : statusColor(entry.status, scheme);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final longest = entry.phases.fold(1, (m, p) => p.ms > m ? p.ms : m);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 680),
        child: DefaultTabController(
          length: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: entry.status == 0
                                      ? 'No response'
                                      : '${entry.status} ${entry.statusText}'
                                            .trim(),
                                  style: TextStyle(color: color),
                                ),
                                TextSpan(text: '  ·  ${entry.method}'),
                              ],
                            ),
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            entry.url,
                            key: const Key('har-detail-url'),
                            style: mono.copyWith(fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${entry.kind} · ${formatSize(entry.sizeBytes)} · '
                            '${formatDuration(entry.timeMs)} · started at '
                            '${formatDuration(entry.offsetMs)}',
                            style: muted,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('har-detail-close'),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              // A single phase would only repeat the total above.
              if (entry.phases.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Column(
                    children: [
                      for (final phase in entry.phases)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 64,
                                child: Text(phase.name, style: muted),
                              ),
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: phase.ms / longest,
                                  minHeight: 6,
                                  borderRadius: BorderRadius.circular(3),
                                  backgroundColor:
                                      scheme.surfaceContainerHighest,
                                ),
                              ),
                              SizedBox(
                                width: 72,
                                child: Text(
                                  formatDuration(phase.ms),
                                  textAlign: TextAlign.right,
                                  style: muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(key: Key('har-detail-request'), text: 'Request'),
                  Tab(key: Key('har-detail-response'), text: 'Response'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _message(
                      theme,
                      entry.requestHeaders,
                      entry.requestBody,
                      null,
                      'No body was sent.',
                    ),
                    _message(
                      theme,
                      entry.responseHeaders,
                      entry.responseBody,
                      entry.bodyNote,
                      'The archive holds no response body.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _message(
    ThemeData theme,
    List<Header> headers,
    String? body,
    String? note,
    String empty,
  ) {
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final small = mono.copyWith(fontSize: 12);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Headers', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          if (headers.isEmpty) Text('None recorded.', style: muted),
          if (headers.isNotEmpty)
            SelectableText.rich(
              TextSpan(
                children: [
                  for (final header in headers) ...[
                    TextSpan(
                      text: '${header.name}: ',
                      style: small.copyWith(color: scheme.primary),
                    ),
                    TextSpan(text: '${header.value}\n', style: small),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text('Body', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          if (note != null) Text(note, style: muted),
          if (body != null)
            SelectableText(_readable(body), style: small)
          else if (note == null)
            Text(empty, style: muted),
        ],
      ),
    );
  }
}
