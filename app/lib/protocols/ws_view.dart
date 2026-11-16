import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/code_controller.dart';

import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/shared/readable.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/shared/theme.dart';

/// One line of a WebSocket conversation: a message either way, or
/// something that happened to the connection.
class WsEntry {
  WsEntry.sent(String text)
    : this._(
        true,
        WsEvent(
          kind: WsEventKind.text,
          text: text,
          data: Uint8List(0),
          code: 0,
          headers: const [],
          atMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  WsEntry.received(WsEvent event) : this._(false, event);

  WsEntry._(this.sent, this.event)
    : at = DateTime.fromMillisecondsSinceEpoch(event.atMs.toInt()),
      text = switch (event.kind) {
        _ when sent => event.text,
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

  /// What the connection reported, or the message as it was sent.
  final WsEvent event;
  final String text;
  final DateTime at;

  WsEventKind get kind => event.kind;

  bool get isMessage => kind == WsEventKind.text || kind == WsEventKind.binary;

  /// This line as the engine writes it to a file.
  WsLine get line => WsLine(sent: sent, event: event);

  /// What the line shows opened up: JSON indented, binary data as
  /// hexadecimal, the handshake's answer with its headers.
  String get whole => switch (kind) {
    WsEventKind.binary => '$text\n${hexPreview(event.data)}',
    WsEventKind.open when event.headers.isNotEmpty =>
      '$text\n${event.headers.map((h) => '${h.name}: ${h.value}').join('\n')}',
    WsEventKind.text => readable(text),
    _ => text,
  };
}

/// Which lines of a conversation are listed.
enum _Show {
  all('All'),
  sent('Sent'),
  received('Received');

  const _Show(this.label);
  final String label;
}

/// The conversation on a WebSocket, newest at the bottom.
class WsLogView extends StatefulWidget {
  const WsLogView({
    super.key,
    required this.entries,
    required this.connected,
    required this.connecting,
    required this.onClear,
    this.onSave,
    this.onAnalyse,
  });

  final List<WsEntry> entries;
  final bool connected;
  final bool connecting;
  final VoidCallback onClear;

  /// Saves the conversation to a file.
  final VoidCallback? onSave;

  /// Opens the conversation in the HAR analyser.
  final VoidCallback? onAnalyse;

  @override
  State<WsLogView> createState() => _WsLogViewState();
}

class _WsLogViewState extends State<WsLogView> {
  /// Lines longer than this are cut short until they are opened.
  static const _closedLines = 3;

  final _scroll = ScrollController();
  final _filter = TextEditingController();
  int _listed = 0;
  bool _searching = false;
  _Show _show = _Show.all;

  /// The lines shown whole.
  final _opened = Set<WsEntry>.identity();

  @override
  void dispose() {
    _scroll.dispose();
    _filter.dispose();
    super.dispose();
  }

  /// Keeps the newest line in view as the conversation grows, unless the
  /// reader has scrolled back to look at something.
  void _follow(int listed) {
    if (listed == _listed) return;
    _listed = listed;
    final atEnd =
        !_scroll.hasClients ||
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
    if (!atEnd) return;
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

  List<WsEntry> get _lines {
    final words = _searching
        ? (_filter.text.toLowerCase().split(' ')..removeWhere((w) => w.isEmpty))
        : const <String>[];
    if (words.isEmpty && _show == _Show.all) return widget.entries;
    return [
      for (final entry in widget.entries)
        if (switch (_show) {
              _Show.all => true,
              _Show.sent => entry.sent,
              _Show.received => !entry.sent && entry.isMessage,
            } &&
            words.every(entry.text.toLowerCase().contains))
          entry,
    ];
  }

  void _toggleSearch() => setState(() {
    _searching = !_searching;
    if (!_searching) _show = _Show.all;
  });

  Future<void> _copy(WsEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: entry.whole));
    notify(messenger, 'Copied');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = widget.entries;
    final lines = _lines;
    _follow(lines.length);
    final messages = entries.where((e) => e.isMessage).length;
    final sent = entries.where((e) => e.sent).length;
    final (label, color) = widget.connected
        ? ('Connected', statusColor(200, scheme))
        : widget.connecting
        ? ('Connecting…', statusColor(300, scheme))
        : ('Disconnected', scheme.outline);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    Widget action(String key, String tip, IconData icon, VoidCallback? run) =>
        IconButton(
          key: Key(key),
          tooltip: tip,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon),
          onPressed: run,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Column(
              children: [
                Row(
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
                      child: Tooltip(
                        message: '$sent sent, ${messages - sent} received',
                        child: Text(
                          '$messages ${messages == 1 ? 'message' : 'messages'}',
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    ),
                    action(
                      'ws-search',
                      _searching ? 'Hide the filter' : 'Filter the log',
                      _searching ? Icons.search_off : Icons.search,
                      entries.isEmpty && !_searching ? null : _toggleSearch,
                    ),
                    if (widget.onAnalyse != null)
                      action(
                        'ws-analyse',
                        'Open in the HAR analyser',
                        Icons.insights_outlined,
                        entries.isEmpty ? null : widget.onAnalyse,
                      ),
                    if (widget.onSave != null)
                      action(
                        'ws-save',
                        'Save the log as a HAR file…',
                        Icons.save_alt,
                        entries.isEmpty ? null : widget.onSave,
                      ),
                    TextButton(
                      key: const Key('ws-clear'),
                      onPressed: entries.isEmpty ? null : widget.onClear,
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                if (_searching)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, right: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('ws-filter'),
                            controller: _filter,
                            autofocus: true,
                            autocorrect: false,
                            style: theme.textTheme.bodySmall,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Text the lines must contain',
                              suffixText: lines.length == entries.length
                                  ? null
                                  : '${lines.length} of ${entries.length}',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<_Show>(
                          key: const Key('ws-show'),
                          value: _show,
                          isDense: true,
                          underline: const SizedBox.shrink(),
                          style: theme.textTheme.bodySmall,
                          items: [
                            for (final show in _Show.values)
                              DropdownMenuItem(
                                value: show,
                                child: Text(show.label),
                              ),
                          ],
                          onChanged: (show) =>
                              setState(() => _show = show ?? _Show.all),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: lines.isEmpty
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
                        entries.isEmpty
                            ? 'Connect to start exchanging messages'
                            : 'No line matches the filter',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: lines.length,
                    itemBuilder: (context, i) => _row(theme, lines[i]),
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
    final opened = _opened.contains(entry);
    // Only a line with more to show can be opened.
    final whole = entry.whole;
    final more =
        whole != entry.text ||
        '\n'.allMatches(whole).length >= _closedLines ||
        whole.length > 240;
    final text = Text(
      opened ? whole : entry.text,
      maxLines: opened ? null : _closedLines,
      overflow: opened ? null : TextOverflow.ellipsis,
      style: mono.copyWith(
        color: entry.kind == WsEventKind.error
            ? scheme.error
            : entry.isMessage
            ? null
            : scheme.onSurfaceVariant,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
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
          Expanded(child: text),
          if (opened)
            _RowAction(
              tip: 'Copy',
              icon: Icons.copy,
              onPressed: () => _copy(entry),
            ),
          if (more)
            _RowAction(
              tip: opened ? 'Show less' : 'Show all of it',
              icon: opened ? Icons.expand_less : Icons.expand_more,
              onPressed: () => setState(
                () => opened ? _opened.remove(entry) : _opened.add(entry),
              ),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// A small button at the end of a line of the log.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.tip,
    required this.icon,
    required this.onPressed,
  });

  final String tip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: IconButton(
      tooltip: tip,
      iconSize: 15,
      padding: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.outline,
      icon: Icon(icon),
      onPressed: onPressed,
    ),
  );
}

/// The Message tab of a WebSocket: what to send next, and a button for it.
class WsComposer extends StatelessWidget {
  const WsComposer({
    super.key,
    required this.controller,
    required this.connected,
    required this.onSend,
    this.variables = const [],
  });

  final CodeController controller;

  /// Names of the variables in reach, offered after `{{`.
  final List<String> variables;
  final bool connected;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // A message is often JSON, but need not be: coloured as it looks.
          child: CodeEditor(
            name: 'ws-message',
            controller: controller,
            hint: 'Message to send, such as {"type": "ping"}',
            variables: variables,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  connected
                      ? 'Sent as a text message. '
                            '${isDesktop ? '$shortcutModifier↵ sends it.' : ''}'
                      : 'Connect first, then send messages from here.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              FilledButton.tonal(
                key: const Key('ws-send'),
                onPressed: connected ? onSend : null,
                child: const Text('Send message'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
