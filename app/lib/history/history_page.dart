import 'package:flutter/material.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/har/har_actions.dart';
import 'package:reqorb/response/response_view.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// Shows every request sent before, newest first. Returns the one chosen
/// to open again, if one was.
Future<HistoryEntry?> showHistory(BuildContext context, WorkspaceStore store) =>
    Navigator.of(context).push(
      MaterialPageRoute<HistoryEntry>(
        fullscreenDialog: true,
        builder: (_) => HistoryPage(store: store),
      ),
    );

/// The heading a request sent at [time] is listed under.
String dayOf(DateTime time, DateTime now) {
  final day = DateTime(time.year, time.month, time.day);
  final today = DateTime(now.year, now.month, now.day);
  final ago = today.difference(day).inDays;
  if (ago <= 0) return 'Today';
  if (ago == 1) return 'Yesterday';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

String _clock(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.store});

  final WorkspaceStore store;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _search = TextEditingController();

  WorkspaceStore get _store => widget.store;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The entries matching every word typed, newest first.
  List<HistoryEntry> _matching() {
    final words = _search.text.toLowerCase().split(' ')
      ..removeWhere((w) => w.isEmpty);
    return [
      for (final entry in _store.history.reversed)
        if (words.every(
          '${entry.exchange.request.method} ${entry.exchange.request.url} '
                  '${entry.exchange.response.status} ${entry.name}'
              .toLowerCase()
              .contains,
        ))
          entry,
    ];
  }

  Future<void> _clear() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: Text(
          'This forgets all ${_store.history.length} requests and their '
          'responses. Saved requests are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('history-clear-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (sure == true) _store.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final entries = _matching();
        final now = DateTime.now();
        final unreadable = _store.unreadableHistory;
        // A heading goes above the first request of each day.
        final rows = <Widget>[];
        String? heading;
        for (final (index, entry) in entries.indexed) {
          final sent = DateTime.fromMillisecondsSinceEpoch(
            entry.exchange.startedMs,
          );
          final day = dayOf(sent, now);
          if (day != heading) {
            heading = day;
            rows.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(
                  day,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }
          rows.add(
            _HistoryRow(
              key: Key('history-row-$index'),
              entry: entry,
              sent: sent,
              onOpen: () => Navigator.of(context).pop(entry),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _store.history.isEmpty
                  ? 'History'
                  : 'History · ${_store.history.length}',
            ),
            actions: [
              IconButton(
                key: const Key('history-analyze'),
                tooltip: 'Analyse history',
                icon: const Icon(Icons.insights),
                onPressed: _store.history.isEmpty
                    ? null
                    : () => showHarAnalysis(
                        context,
                        _store,
                        name: 'History',
                        text: Engine.of(context).exportHar(
                          exchanges: [
                            for (final e in _store.history) e.exchange,
                          ],
                        ),
                      ),
              ),
              IconButton(
                key: const Key('history-clear'),
                tooltip: 'Clear history',
                icon: const Icon(Icons.delete_outline),
                onPressed: _store.history.isEmpty && unreadable == 0
                    ? null
                    : _clear,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  key: const Key('history-search'),
                  controller: _search,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Search by address, method, status or name',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (unreadable > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Text(
                    '$unreadable earlier '
                    '${unreadable == 1 ? 'request' : 'requests'} cannot be '
                    'shown: they were encrypted with a key that is not in '
                    'this keychain.',
                    key: const Key('history-unreadable'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _store.history.isEmpty
                                ? _store.settings.historyLimit == 0
                                      ? 'History is switched off in Settings.'
                                      : 'Requests you send are listed here, '
                                            'with their responses.'
                                : 'No request matches',
                            key: const Key('history-empty'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      )
                    : ListView(children: rows),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.entry,
    required this.sent,
    required this.onOpen,
  });

  final HistoryEntry entry;
  final DateTime sent;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final request = entry.exchange.request;
    final response = entry.exchange.response;
    final small = mono.copyWith(fontSize: 12);
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final uri = Uri.tryParse(request.url);
    final path = uri == null || uri.host.isEmpty
        ? request.url
        : '${uri.path.isEmpty ? '/' : uri.path}'
              '${uri.hasQuery ? '?${uri.query}' : ''}';
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Text(
                '${response.status}',
                style: small.copyWith(
                  color: statusColor(response.status, scheme),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(
              width: 58,
              child: Text(
                request.method,
                overflow: TextOverflow.ellipsis,
                style: small.copyWith(
                  color: methodColor(request.method, scheme.brightness),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name.isEmpty ? path : entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: entry.name.isEmpty ? small : null,
                  ),
                  Text(
                    [
                      if (entry.name.isNotEmpty) path,
                      if (uri != null && uri.host.isNotEmpty) uri.host,
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${response.elapsedMs} ms  ·  '
              '${formatSize(response.sizeBytes)}  ·  ${_clock(sent)}',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}
