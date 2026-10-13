/// Server-Sent Events: reading a `text/event-stream` body as the events it
/// carries, and listing them.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';

/// One event of a stream.
class SseEvent {
  const SseEvent({required this.event, required this.data, this.id = ''});

  /// The event's type; `message` when the stream does not name one.
  final String event;
  final String data;
  final String id;
}

/// The events in [text], in the order they were sent. An event still being
/// written, with no blank line after it yet, is not one of them, and
/// neither is one that carries no data.
List<SseEvent> parseSse(String text) {
  final events = <SseEvent>[];
  var event = '';
  var id = '';
  final data = <String>[];
  for (final line in const LineSplitter().convert(
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
  )) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        events.add(
          SseEvent(
            event: event.isEmpty ? 'message' : event,
            data: data.join('\n'),
            id: id,
          ),
        );
      }
      event = '';
      data.clear();
      continue;
    }
    // A line that starts with a colon is a comment, often a keep-alive.
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
      case 'id':
        // The id stays in force for the events after it.
        id = value;
    }
  }
  // The text ends without a line break only when the last line is partial,
  // and without a blank line when the last event is.
  return events;
}

/// The events of a stream, newest at the bottom. While the stream is
/// [live] the list follows it, unless it has been scrolled away from the
/// end to read something earlier.
class EventsView extends StatefulWidget {
  const EventsView({super.key, required this.events, required this.live});

  final List<SseEvent> events;
  final bool live;

  @override
  State<EventsView> createState() => _EventsViewState();
}

class _EventsViewState extends State<EventsView> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(EventsView old) {
    super.didUpdateWidget(old);
    if (widget.events.length == old.events.length || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final atEnd = position.pixels >= position.maxScrollExtent - 48;
    if (!atEnd) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final events = widget.events;
    if (events.isEmpty) {
      return Center(
        child: Text(
          widget.live ? 'Waiting for the first event…' : 'No events were sent',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return SelectionArea(
      child: ListView.separated(
        key: const Key('events'),
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: events.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
        itemBuilder: (context, i) {
          final event = events[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 40, child: Text('${i + 1}', style: small)),
                SizedBox(
                  width: 120,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.event,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: event.event == 'message'
                              ? scheme.onSurfaceVariant
                              : scheme.primary,
                        ),
                      ),
                      if (event.id.isNotEmpty)
                        Text(
                          'id ${event.id}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: small,
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Text(event.data, style: mono.copyWith(fontSize: 12.5)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
