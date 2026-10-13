import 'package:flutter/material.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/code_controller.dart';

import 'package:reqorb/shared/theme.dart';

/// One `key: value` line; a line without a colon is a key with no value.
(String, String)? parseKeyValueLine(String line) {
  line = line.trim();
  if (line.isEmpty) return null;
  final i = line.indexOf(':');
  if (i < 0) return (line, '');
  return (line.substring(0, i).trim(), line.substring(i + 1).trim());
}

/// The query string of [url] as `key:value` lines, exactly as written.
String paramsTextFromUrl(String url) {
  final hash = url.indexOf('#');
  final withoutFragment = hash < 0 ? url : url.substring(0, hash);
  final mark = withoutFragment.indexOf('?');
  if (mark < 0) return '';
  return [
    for (final pair in withoutFragment.substring(mark + 1).split('&'))
      if (pair.isNotEmpty)
        switch (pair.indexOf('=')) {
          < 0 => pair,
          final i => '${pair.substring(0, i)}:${pair.substring(i + 1)}',
        },
  ].join('\n');
}

/// [url] with its query string replaced by the `key:value` lines in [text].
/// Nothing is encoded here, so `{{variables}}` survive; encoding happens
/// when the request is sent.
String urlWithParamsText(String url, String text) {
  final hash = url.indexOf('#');
  final fragment = hash < 0 ? '' : url.substring(hash);
  var base = hash < 0 ? url : url.substring(0, hash);
  final mark = base.indexOf('?');
  if (mark >= 0) base = base.substring(0, mark);
  final query = [
    for (final line in text.split('\n'))
      if (parseKeyValueLine(line) case (final key, final value))
        if (key.isNotEmpty || value.isNotEmpty)
          value.isEmpty ? key : '$key=$value',
  ].join('&');
  return query.isEmpty ? '$base$fragment' : '$base?$query$fragment';
}

/// Edits `key: value` lines either as a table or, with Bulk Edit, as text.
///
/// [controller] always holds the text form, so the two views and anything
/// else that changes the text stay in step.
class KeyValueEditor extends StatefulWidget {
  const KeyValueEditor({
    super.key,
    required this.controller,
    required this.name,
    required this.bulk,
    required this.onBulkChanged,
    required this.bulkHint,
    this.variables = const [],
    this.keyLabel = 'Key',
    this.valueLabel = 'Value',
    this.separator = ': ',
  });

  final CodeController controller;

  /// Names of the variables in reach, offered after `{{`.
  final List<String> variables;

  /// Prefix for widget keys; the bulk text field's key is exactly this.
  final String name;
  final bool bulk;
  final ValueChanged<bool> onBulkChanged;
  final String bulkHint;
  final String keyLabel;
  final String valueLabel;

  /// Written between key and value when the table is turned back into text.
  final String separator;

  @override
  State<KeyValueEditor> createState() => _KeyValueEditorState();
}

class _Row {
  _Row(String key, String value)
    : key = TextEditingController(text: key),
      value = TextEditingController(text: value);

  final TextEditingController key;
  final TextEditingController value;

  bool get isBlank => key.text.trim().isEmpty && value.text.trim().isEmpty;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

/// Width kept at the end of every row for its remove button.
const _removeWidth = 36.0;

class _KeyValueEditorState extends State<KeyValueEditor> {
  final _rows = <_Row>[];

  /// Set while the table writes its own rows back to the text, so that the
  /// resulting notification does not rebuild the rows being typed in.
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    _readText();
    widget.controller.addListener(_textChanged);
  }

  @override
  void didUpdateWidget(KeyValueEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_textChanged);
      widget.controller.addListener(_textChanged);
      _readText();
    } else if (old.bulk && !widget.bulk) {
      _readText();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_textChanged);
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _textChanged() {
    if (_writing || widget.bulk || !mounted) return;
    setState(_readText);
  }

  /// Rebuilds the rows from the text, leaving one blank row to type into.
  void _readText() {
    for (final row in _rows) {
      row.dispose();
    }
    _rows
      ..clear()
      ..addAll([
        for (final line in widget.controller.text.split('\n'))
          if (parseKeyValueLine(line) case (final key, final value))
            _Row(key, value),
        _Row('', ''),
      ]);
  }

  void _writeText() {
    _writing = true;
    widget.controller.text = [
      for (final row in _rows)
        if (!row.isBlank)
          row.value.text.trim().isEmpty
              ? row.key.text.trim()
              : '${row.key.text.trim()}${widget.separator}'
                    '${row.value.text.trim()}',
    ].join('\n');
    _writing = false;
    if (!_rows.last.isBlank) setState(() => _rows.add(_Row('', '')));
  }

  void _remove(int index) {
    setState(() {
      _rows.removeAt(index).dispose();
      if (_rows.isEmpty) _rows.add(_Row('', ''));
    });
    _writeText();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Laid out like a table row, so each label sits over its column.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: Row(
            children: [
              if (!widget.bulk) ...[
                Expanded(child: Text(widget.keyLabel, style: label)),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.bulk
                            ? 'One ${widget.keyLabel.toLowerCase()}'
                                  '${widget.separator.trim()}'
                                  '${widget.valueLabel.toLowerCase()} per line'
                            : widget.valueLabel,
                        style: label,
                      ),
                    ),
                    TextButton(
                      key: Key('${widget.name}-bulk-toggle'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => widget.onBulkChanged(!widget.bulk),
                      child: Text(widget.bulk ? 'Key-Value Edit' : 'Bulk Edit'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: _removeWidth),
            ],
          ),
        ),
        Expanded(child: widget.bulk ? _bulk() : _table()),
      ],
    );
  }

  Widget _bulk() {
    return CodeEditor(
      name: widget.name,
      controller: widget.controller,
      language: CodeLanguage.pairs,
      hint: widget.bulkHint,
      hintLines: 2,
      variables: widget.variables,
    );
  }

  Widget _table() {
    // A column, not a lazy list: there are few rows, and each one should
    // exist even while scrolled out of a short pane.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 12),
      child: Column(children: [for (var i = 0; i < _rows.length; i++) _row(i)]),
    );
  }

  Widget _row(int index) {
    final row = _rows[index];
    final isLast = index == _rows.length - 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: _cell(
              Key('${widget.name}-key-$index'),
              row.key,
              widget.keyLabel,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _cell(
              Key('${widget.name}-value-$index'),
              row.value,
              widget.valueLabel,
            ),
          ),
          // The trailing blank row has nothing to remove yet.
          SizedBox(
            width: _removeWidth,
            child: Visibility.maintain(
              visible: !isLast,
              child: IconButton(
                key: Key('${widget.name}-remove-$index'),
                tooltip: 'Remove',
                iconSize: 16,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: isLast ? null : () => _remove(index),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(Key key, TextEditingController controller, String hint) {
    return TextField(
      key: key,
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      smartQuotesType: SmartQuotesType.disabled,
      smartDashesType: SmartDashesType.disabled,
      style: mono,
      decoration: InputDecoration(isDense: true, hintText: hint),
      onChanged: (_) => _writeText(),
    );
  }
}
