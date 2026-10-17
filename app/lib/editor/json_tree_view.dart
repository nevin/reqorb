import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/response/response_view.dart' show formatSize;
import 'package:reqorb/shared/theme.dart';

/// How many children are listed at a time; more come with a tap.
const jsonPage = 200;

/// One row of the tree as shown: a value, or the row that brings more of
/// an object or array's children.
class _Entry {
  _Entry.node(this.node, this.depth, [this.index = 0])
    : parent = null,
      from = null;
  _Entry.more(_Entry this.parent, int this.from, this.depth)
    : node = null,
      index = 0;

  final DocJsonNode? node;
  final int depth;

  /// Where it is among its parent's children, counted from 0.
  final int index;

  /// For a "more" row: whose children, and where they go on from.
  final _Entry? parent;
  final int? from;

  bool open = false;
  bool loading = false;

  /// How many of its children have been listed so far.
  int listed = 0;

  /// How many children it has, once all of them have been listed.
  int? count;
}

/// A document's JSON as a tree, opened a level at a time. Only the
/// children of what is opened are read, a page at a time, so a gigabyte
/// of JSON is explored as easily as a kilobyte.
///
/// Keyed `<name>`; each row `<name>-row-<n>`, its arrow `<name>-open-<n>`,
/// and the row bringing more `<name>-more-<n>`.
class JsonTreeView extends StatefulWidget {
  const JsonTreeView({
    super.key,
    required this.document,
    this.name = 'tree',
    this.onShow,
  });

  final TextDocument document;
  final String name;

  /// Shows a value in the text; none to offer nothing.
  final ValueChanged<DocJsonNode>? onShow;

  @override
  State<JsonTreeView> createState() => _JsonTreeViewState();
}

class _JsonTreeViewState extends State<JsonTreeView> {
  final _scroll = ScrollController();
  final _entries = <_Entry>[];
  String? _error;
  bool _reading = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(JsonTreeView old) {
    super.didUpdateWidget(old);
    if (old.document != widget.document) _start();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final document = widget.document;
    setState(() {
      _entries.clear();
      _error = null;
      _reading = true;
    });
    try {
      final root = await document.jsonRoot();
      if (!mounted || document != widget.document) return;
      final entry = _Entry.node(root, 0);
      setState(() {
        _entries.add(entry);
        _reading = false;
      });
      if (_container(root)) await _toggle(entry);
    } catch (e) {
      if (!mounted || document != widget.document) return;
      setState(() {
        _error = '$e';
        _reading = false;
      });
    }
  }

  static bool _container(DocJsonNode node) =>
      node.kind == DocJsonKind.object || node.kind == DocJsonKind.array;

  /// Opens or closes [entry]'s children.
  Future<void> _toggle(_Entry entry) async {
    final at = _entries.indexOf(entry);
    if (at < 0 || entry.loading) return;
    if (entry.open) {
      var end = at + 1;
      while (end < _entries.length && _entries[end].depth > entry.depth) {
        end++;
      }
      setState(() {
        _entries.removeRange(at + 1, end);
        entry.open = false;
      });
      return;
    }
    setState(() {
      entry.open = true;
      entry.loading = true;
      entry.listed = 0;
      entry.count = null;
    });
    await _load(entry, null, at + 1);
  }

  /// Lists a page of [parent]'s children from [from], at [index].
  Future<void> _load(_Entry parent, int? from, int index) async {
    try {
      final page = await widget.document.jsonChildren(
        parent.node!.start,
        from: from,
        count: jsonPage,
      );
      if (!mounted || !parent.open) return;
      setState(() {
        parent.loading = false;
        final rows = [
          for (final node in page.nodes)
            _Entry.node(node, parent.depth + 1, parent.listed++),
          if (page.next case final next?)
            _Entry.more(parent, next, parent.depth + 1),
        ];
        _entries.insertAll(index, rows);
        if (page.next == null) parent.count = parent.listed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        parent.loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _more(_Entry more) async {
    final at = _entries.indexOf(more);
    if (at < 0 || more.loading) return;
    setState(() => more.loading = true);
    final parent = more.parent!;
    setState(() => _entries.removeAt(at));
    await _load(parent, more.from, at);
  }

  Widget _row(BuildContext context, int index) {
    final entry = _entries[index];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final name = widget.name;
    final indent = 12.0 + entry.depth * 18;
    if (entry.node == null) {
      return Padding(
        padding: EdgeInsets.only(left: indent + 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: Key('$name-more-$index'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: entry.loading ? null : () => _more(entry),
            child: Text('Show $jsonPage more'),
          ),
        ),
      );
    }
    final node = entry.node!;
    final container = _container(node);
    final spans = <TextSpan>[
      if (node.key case final key?)
        TextSpan(
          text: '"$key": ',
          style: TextStyle(color: tokenColor(TokenKind.key, brightness)),
        )
      else if (entry.depth > 0)
        TextSpan(
          text: '${entry.index}: ',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
    ];
    if (container) {
      final object = node.kind == DocJsonKind.object;
      final count = entry.count;
      spans.add(
        TextSpan(
          text: object ? '{…}' : '[…]',
          style: TextStyle(color: scheme.onSurface),
        ),
      );
      spans.add(
        TextSpan(
          text:
              '  ${count == null ? '' : '$count ${object ? (count == 1 ? 'key' : 'keys') : (count == 1 ? 'item' : 'items')} · '}'
              '${formatSize(node.end - node.start)}',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    } else {
      final kind = switch (node.kind) {
        DocJsonKind.string => TokenKind.string,
        DocJsonKind.number => TokenKind.number,
        _ => TokenKind.keyword,
      };
      final cut = node.end - node.start > node.preview.length + 2;
      final text = node.kind == DocJsonKind.string
          ? '"${node.preview}${cut ? '…' : '"'}'
          : '${node.preview}${cut ? '…' : ''}';
      spans.add(
        TextSpan(
          text: text,
          style: TextStyle(color: tokenColor(kind, brightness)),
        ),
      );
    }
    return InkWell(
      key: Key('$name-row-$index'),
      onTap: container
          ? () => _toggle(entry)
          : widget.onShow == null
          ? null
          : () => widget.onShow!(node),
      onLongPress: widget.onShow == null ? null : () => widget.onShow!(node),
      child: Padding(
        padding: EdgeInsets.only(left: indent),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: container
                  ? (entry.loading
                        ? const SizedBox.square(
                            dimension: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : Icon(
                            entry.open
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            key: Key('$name-open-$index'),
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ))
                  : null,
            ),
            Expanded(
              child: Text.rich(
                TextSpan(children: spans),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_reading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              'Reading the JSON…',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              error,
              key: Key('${widget.name}-error'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView.builder(
              key: Key(widget.name),
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemExtent: (CodeStyle.fontSize * 1.4).ceilToDouble() + 8,
              itemCount: _entries.length,
              itemBuilder: _row,
            ),
          ),
        ),
      ],
    );
  }
}
