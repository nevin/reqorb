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

  /// Imports the archive's requests as a collection.
  final Future<void> Function(BuildContext context) onImport;

  @override
  State<HarAnalysisPage> createState() => _HarAnalysisPageState();
}

class _HarAnalysisPageState extends State<HarAnalysisPage> {
  /// The finding whose requests the table is narrowed to, if any.
  HarFinding? _finding;
  _Sort _sort = _Sort.order;

  /// The heading of the request table.
  final _requests = GlobalKey();

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
    final rows =
        _finding?.entries.toList() ??
        [for (var i = 0; i < entries.length; i++) i];
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
    return Scaffold(
      appBar: AppBar(
        title: Text('HAR analysis · ${widget.name}'),
        actions: [
          TextButton.icon(
            key: const Key('har-import'),
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: const Text('Import as collection'),
            onPressed: report.entries.isEmpty
                ? null
                : () => widget.onImport(context),
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
                      const Divider(height: 16),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) => _EntryRow(
                    key: Key('har-entry-${rows[i]}'),
                    entry: report.entries[rows[i]],
                    spanMs: report.spanMs,
                    timeline: timeline,
                  ),
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
    required this.entry,
    required this.spanMs,
    required this.timeline,
  });

  final HarEntry entry;
  final int spanMs;
  final bool timeline;

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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
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
