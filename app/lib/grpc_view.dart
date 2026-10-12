import 'package:flutter/material.dart';

import 'response_view.dart';
import 'src/rust/api/core.dart';
import 'theme.dart';

/// Splits the editor's text into the messages of a call: one, or several
/// separated by lines holding only `---` for a client stream.
List<String> grpcMessages(String text) {
  final messages = <String>[];
  final current = StringBuffer();
  for (final line in text.split('\n')) {
    if (line.trim() == '---') {
      messages.add(current.toString().trim());
      current.clear();
    } else {
      current.writeln(line);
    }
  }
  messages.add(current.toString().trim());
  return [
    for (final message in messages)
      if (message.isNotEmpty) message,
  ];
}

String _kind(GrpcMethod method) =>
    switch ((method.clientStreaming, method.serverStreaming)) {
      (false, false) => 'Unary',
      (true, false) => 'Client stream',
      (false, true) => 'Server stream',
      (true, true) => 'Two-way stream',
    };

/// The Message tab of a gRPC request: which method to call, where its
/// definition comes from, and the message to send as JSON.
class GrpcComposer extends StatelessWidget {
  const GrpcComposer({
    super.key,
    required this.controller,
    required this.schema,
    required this.method,
    required this.protoPath,
    required this.loading,
    required this.onMethod,
    required this.onReflect,
    required this.onChooseProto,
  });

  final TextEditingController controller;

  /// The server's methods, once loaded.
  final GrpcSchema? schema;

  /// The chosen method as `package.Service/Method`.
  final String? method;

  /// The `.proto` file the methods came from; null means reflection.
  final String? protoPath;
  final bool loading;
  final ValueChanged<String> onMethod;
  final VoidCallback onReflect;
  final VoidCallback onChooseProto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final methods = schema?.methods ?? const <GrpcMethod>[];
    final chosen = methods.where((m) => m.path == method).firstOrNull;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  // Rebuilt when the list changes, so a stale choice cannot linger.
                  key: ValueKey('grpc-method-${methods.length}-$method'),
                  isExpanded: true,
                  initialValue: method,
                  decoration: InputDecoration(
                    labelText: 'Method',
                    hintText: loading ? 'Loading…' : 'Load the methods first',
                  ),
                  items: [
                    // A saved choice is shown even before the list is loaded.
                    if (method != null && chosen == null)
                      DropdownMenuItem(value: method, child: Text(method!)),
                    for (final m in methods)
                      DropdownMenuItem(
                        value: m.path,
                        child: Text(
                          m.path,
                          overflow: TextOverflow.ellipsis,
                          style: mono,
                        ),
                      ),
                  ],
                  onChanged: (path) {
                    if (path != null) onMethod(path);
                  },
                ),
              ),
              const SizedBox(width: 4),
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  key: const Key('grpc-reflect'),
                  tooltip: 'Load methods from the server (reflection)',
                  icon: const Icon(Icons.sync),
                  onPressed: onReflect,
                ),
              IconButton(
                key: const Key('grpc-proto'),
                tooltip: 'Load methods from a .proto file',
                icon: const Icon(Icons.description_outlined),
                onPressed: loading ? null : onChooseProto,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Text(
            [
              if (chosen != null) _kind(chosen),
              if (schema != null)
                protoPath == null
                    ? 'methods from server reflection'
                    : 'methods from ${protoPath!.split('/').last}',
              if (chosen?.clientStreaming ?? false)
                'separate messages with a line of ---',
            ].join(' · '),
            key: const Key('grpc-info'),
            style: muted,
          ),
        ),
        Expanded(
          child: TextField(
            key: const Key('grpc-message'),
            controller: controller,
            maxLines: null,
            expands: true,
            autocorrect: false,
            enableSuggestions: false,
            smartQuotesType: SmartQuotesType.disabled,
            smartDashesType: SmartDashesType.disabled,
            textAlignVertical: TextAlignVertical.top,
            style: mono,
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.all(12),
              hintText: 'The request message as JSON, such as {"name": "x"}',
            ),
          ),
        ),
      ],
    );
  }
}

/// The result of a gRPC call: its status, each response message, and the
/// metadata that came with them.
class GrpcReplyView extends StatelessWidget {
  const GrpcReplyView({
    super.key,
    required this.reply,
    required this.error,
    required this.calling,
  });

  final GrpcReply? reply;
  final String? error;
  final bool calling;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reply = this.reply;
    if (calling) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text('Calling…', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    if (error != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText(
                error!,
                key: const Key('grpc-error'),
                style: mono,
              ),
            ),
          ],
        ),
      );
    }
    if (reply == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 32, color: scheme.outlineVariant),
            const SizedBox(height: 12),
            Text(
              'Choose a method and invoke it to see the reply',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final ok = reply.code == 0;
    final color = ok ? statusColor(200, scheme) : scheme.error;
    final count = reply.messages.length;
    final metadata = [...reply.headers, ...reply.trailers];
    return DefaultTabController(
      length: 2,
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
                      '${reply.code} ${reply.status}',
                      key: const Key('grpc-status'),
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Text(
                  '${reply.elapsedMs} ms',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (reply.message.isNotEmpty)
                  Text(
                    reply.message,
                    style: TextStyle(color: scheme.error, fontSize: 13),
                  ),
              ],
            ),
          ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(height: 38, text: 'Messages ($count)'),
              Tab(height: 38, text: 'Metadata (${metadata.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                count == 0
                    ? Center(
                        child: Text(
                          'The server sent no messages',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: count,
                        separatorBuilder: (_, _) => const Divider(height: 24),
                        itemBuilder: (context, i) => SelectableText.rich(
                          TextSpan(
                            style: mono,
                            children: jsonSpans(
                              reply.messages[i],
                              theme.brightness,
                            ),
                          ),
                          key: Key('grpc-reply-$i'),
                        ),
                      ),
                SelectionArea(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final entry in metadata)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 2,
                                child: Text(
                                  entry.name,
                                  style: mono.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 5,
                                child: Text(entry.value, style: mono),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
