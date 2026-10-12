import 'package:flutter/material.dart';

import 'src/rust/api/core.dart';
import 'theme.dart';

/// One line of a WebSocket conversation: a message either way, or
/// something that happened to the connection.
class WsEntry {
  WsEntry.sent(this.text)
    : sent = true,
      kind = WsEventKind.text,
      at = DateTime.now();

  WsEntry.received(WsEvent event)
    : sent = false,
      kind = event.kind,
      at = DateTime.fromMillisecondsSinceEpoch(event.atMs.toInt()),
      text = switch (event.kind) {
        WsEventKind.open => 'Connected · ${event.code} ${event.text}',
        WsEventKind.closed =>
          'Disconnected · ${event.text}'
              '${event.code == 0 ? '' : ' (code ${event.code})'}',
        WsEventKind.binary => '[${event.data.length} bytes of binary data]',
        WsEventKind.ping => 'ping',
        WsEventKind.pong => 'pong',
        _ => event.text,
      };

  /// Whether this is a message the user sent.
  final bool sent;
  final WsEventKind kind;
  final String text;
  final DateTime at;

  bool get isMessage => kind == WsEventKind.text || kind == WsEventKind.binary;
}

/// The conversation on a WebSocket, newest at the bottom.
class WsLogView extends StatefulWidget {
  const WsLogView({
    super.key,
    required this.entries,
    required this.connected,
    required this.connecting,
    required this.onClear,
  });

  final List<WsEntry> entries;
  final bool connected;
  final bool connecting;
  final VoidCallback onClear;

  @override
  State<WsLogView> createState() => _WsLogViewState();
}

class _WsLogViewState extends State<WsLogView> {
  final _scroll = ScrollController();
  int _shown = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the newest line in view as the conversation grows.
  void _follow() {
    if (widget.entries.length == _shown) return;
    _shown = widget.entries.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  static String _time(DateTime at) {
    String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    return '${pad(at.hour)}:${pad(at.minute)}:${pad(at.second)}'
        '.${pad(at.millisecond, 3)}';
  }

  @override
  Widget build(BuildContext context) {
    _follow();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = widget.entries;
    final messages = entries.where((e) => e.isMessage).length;
    final (label, color) = widget.connected
        ? ('Connected', statusColor(200, scheme))
        : widget.connecting
        ? ('Connecting…', statusColor(300, scheme))
        : ('Disconnected', scheme.outline);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: [
                Icon(Icons.circle, size: 9, color: color),
                const SizedBox(width: 8),
                Text(
                  label,
                  key: const Key('ws-status'),
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '$messages ${messages == 1 ? 'message' : 'messages'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('ws-clear'),
                  onPressed: entries.isEmpty ? null : widget.onClear,
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.swap_vert,
                        size: 32,
                        color: scheme.outlineVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Connect to start exchanging messages',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: entries.length,
                    itemBuilder: (context, i) => _row(theme, entries[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, WsEntry entry) {
    final scheme = theme.colorScheme;
    final (icon, color, tip) = switch (entry) {
      WsEntry(sent: true) => (Icons.arrow_upward, scheme.primary, 'Sent'),
      WsEntry(kind: WsEventKind.error) => (
        Icons.error_outline,
        scheme.error,
        'Error',
      ),
      WsEntry(isMessage: true) => (
        Icons.arrow_downward,
        statusColor(200, scheme),
        'Received',
      ),
      _ => (Icons.info_outline, scheme.outline, 'Connection'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Tooltip(
              message: tip,
              child: Icon(icon, size: 15, color: color),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _time(entry.at),
            style: mono.copyWith(fontSize: 11.5, color: scheme.outline),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.text,
              style: mono.copyWith(
                color: entry.kind == WsEventKind.error
                    ? scheme.error
                    : entry.isMessage
                    ? null
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
