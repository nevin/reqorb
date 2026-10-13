import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide FormField;

import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/shared/folders.dart';
import 'package:reqorb/request/key_value_editor.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/shared/theme.dart';

/// Content types offered for a raw body, by the name shown in the picker.
const rawLanguages = {
  'Text': 'text/plain',
  'JSON': 'application/json',
  'XML': 'application/xml',
  'HTML': 'text/html',
  'JavaScript': 'application/javascript',
};

const _modeLabels = {
  BodyMode.none: 'none',
  BodyMode.formData: 'form-data',
  BodyMode.urlEncoded: 'x-www-form-urlencoded',
  BodyMode.raw: 'raw',
  BodyMode.binary: 'binary',
  BodyMode.graphQl: 'GraphQL',
};

/// Asks for a file, starting in the working directory, and returns its
/// path, or null when cancelled. A file inside the working directory comes
/// back relative to it.
Future<String?> pickFilePath() async {
  final start = WorkingDir.path;
  final file = await FilePicker.pickFile(
    initialDirectory: start.isEmpty ? null : start,
  );
  final path = file?.path;
  return path == null ? null : WorkingDir.relative(path);
}

/// The Body tab: a body type picker and the editor for that type.
/// The page owns all the state, so switching type loses nothing.
class BodyEditor extends StatelessWidget {
  const BodyEditor({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.raw,
    required this.rawLanguage,
    this.variables = const [],
    required this.onRawLanguageChanged,
    required this.urlEncoded,
    required this.urlEncodedBulk,
    required this.onUrlEncodedBulkChanged,
    required this.formData,
    required this.binary,
    required this.graphql,
  });

  final BodyMode mode;
  final ValueChanged<BodyMode> onModeChanged;

  final CodeController raw;

  /// The name from [rawLanguages] matching the Content-Type header, if any.
  final String? rawLanguage;

  /// Names of the variables in reach, offered after `{{`.
  final List<String> variables;
  final ValueChanged<String> onRawLanguageChanged;

  /// Url-encoded fields as `key: value` lines.
  final CodeController urlEncoded;
  final bool urlEncodedBulk;
  final ValueChanged<bool> onUrlEncodedBulkChanged;

  /// The form-data table, which keeps its own rows.
  final Widget formData;

  /// Path of the file to send as the body.
  final TextEditingController binary;

  /// The GraphQL editor, which the page builds from the request's query.
  final Widget graphql;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One line: the types scroll sideways in a narrow pane rather than
        // wrapping, and the raw type picker stays in view beside them.
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  spacing: 6,
                  children: [
                    for (final entry in _modeLabels.entries)
                      ChoiceChip(
                        key: Key('body-mode-${entry.value}'),
                        label: Text(entry.value),
                        labelStyle: const TextStyle(fontSize: 13),
                        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                        selected: mode == entry.key,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => onModeChanged(entry.key),
                      ),
                  ],
                ),
              ),
            ),
            if (mode == BodyMode.raw)
              Padding(
                padding: const EdgeInsets.only(right: 12, top: 4),
                child: DropdownButton<String>(
                  key: const Key('body-raw-language'),
                  value: rawLanguage,
                  hint: const Text('Type'),
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final name in rawLanguages.keys)
                      DropdownMenuItem(value: name, child: Text(name)),
                  ],
                  onChanged: (name) {
                    if (name != null) onRawLanguageChanged(name);
                  },
                ),
              ),
          ],
        ),
        Expanded(
          child: switch (mode) {
            BodyMode.none => Center(
              child: Text(
                'This request does not have a body',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            BodyMode.raw => CodeEditor(
              name: 'body',
              controller: raw,
              // As labelled; otherwise as it looks.
              language: rawLanguage == null
                  ? null
                  : CodeLanguage.ofContentType(rawLanguages[rawLanguage]!),
              variables: variables,
              hint: '{ "name": "reqorb" }',
            ),
            BodyMode.urlEncoded => KeyValueEditor(
              controller: urlEncoded,
              name: 'urlencoded',
              bulk: urlEncodedBulk,
              onBulkChanged: onUrlEncodedBulkChanged,
              bulkHint: 'username: alice\ngrant_type: password',
              variables: variables,
            ),
            BodyMode.formData => formData,
            BodyMode.graphQl => graphql,
            // Scrollable, so a short pane cannot clip the explanation.
            BodyMode.binary => SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PathField(
                    fieldKey: const Key('body-binary'),
                    browseKey: const Key('body-binary-browse'),
                    controller: binary,
                    hint: 'Path of the file to send',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The file\'s bytes are sent as the body. Set a '
                    'Content-Type header if the server needs one.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          },
        ),
      ],
    );
  }
}

/// A path that can be typed or chosen with the system file picker.
class _PathField extends StatelessWidget {
  const _PathField({
    required this.fieldKey,
    required this.browseKey,
    required this.controller,
    required this.hint,
    this.onChanged,
  });

  final Key fieldKey;
  final Key browseKey;
  final TextEditingController controller;
  final String hint;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      smartQuotesType: SmartQuotesType.disabled,
      smartDashesType: SmartDashesType.disabled,
      style: mono,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        suffixIcon: IconButton(
          key: browseKey,
          tooltip: 'Choose file',
          iconSize: 18,
          icon: const Icon(Icons.folder_open_outlined),
          onPressed: () async {
            final path = await pickFilePath();
            if (path == null) return;
            controller.text = path;
            onChanged?.call();
          },
        ),
      ),
      onChanged: (_) => onChanged?.call(),
    );
  }
}

/// Widths of the type picker and the remove button in a form-data row.
const _typeWidth = 64.0;
const _removeWidth = 36.0;

class _FormRow {
  _FormRow(FormField field)
    : key = TextEditingController(text: field.key),
      value = TextEditingController(text: field.value),
      file = field.file;

  final TextEditingController key;
  final TextEditingController value;
  bool file;

  bool get isBlank => key.text.trim().isEmpty && value.text.trim().isEmpty;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

/// The form-data table: each row is a text value or a file to upload.
/// Give the widget a new [key] to load a different request's fields.
class FormDataEditor extends StatefulWidget {
  const FormDataEditor({
    super.key,
    required this.fields,
    required this.onChanged,
  });

  final List<FormField> fields;
  final ValueChanged<List<FormField>> onChanged;

  @override
  State<FormDataEditor> createState() => _FormDataEditorState();
}

class _FormDataEditorState extends State<FormDataEditor> {
  static const _blank = FormField(key: '', value: '', file: false);

  late final _rows = [
    for (final field in widget.fields) _FormRow(field),
    _FormRow(_blank),
  ];

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _emit() {
    widget.onChanged([
      for (final row in _rows)
        if (!row.isBlank)
          FormField(
            key: row.key.text.trim(),
            value: row.value.text.trim(),
            file: row.file,
          ),
    ]);
    // Always leave one empty row to type into.
    if (!_rows.last.isBlank) setState(() => _rows.add(_FormRow(_blank)));
  }

  @override
  Widget build(BuildContext context) {
    // A column, not a lazy list: there are few rows, and each one should
    // exist even while scrolled out of a short pane.
    final theme = Theme.of(context);
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
      child: Column(
        children: [
          // Mirrors a row, so each label sits over its column.
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(flex: 2, child: Text('Key', style: label)),
                const SizedBox(width: _typeWidth + 12),
                Expanded(flex: 3, child: Text('Value', style: label)),
                const SizedBox(width: _removeWidth),
              ],
            ),
          ),
          for (var i = 0; i < _rows.length; i++) _row(i),
        ],
      ),
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
            flex: 2,
            child: TextField(
              key: Key('form-key-$index'),
              controller: row.key,
              autocorrect: false,
              enableSuggestions: false,
              smartQuotesType: SmartQuotesType.disabled,
              smartDashesType: SmartDashesType.disabled,
              style: mono,
              decoration: const InputDecoration(isDense: true, hintText: 'Key'),
              onChanged: (_) => _emit(),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: _typeWidth,
            child: DropdownButton<bool>(
              key: Key('form-type-$index'),
              value: row.file,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: false, child: Text('Text')),
                DropdownMenuItem(value: true, child: Text('File')),
              ],
              onChanged: (file) {
                setState(() => row.file = file ?? false);
                _emit();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: row.file
                ? _PathField(
                    fieldKey: Key('form-value-$index'),
                    browseKey: Key('form-browse-$index'),
                    controller: row.value,
                    hint: 'File path',
                    onChanged: _emit,
                  )
                : TextField(
                    key: Key('form-value-$index'),
                    controller: row.value,
                    autocorrect: false,
                    enableSuggestions: false,
                    smartQuotesType: SmartQuotesType.disabled,
                    smartDashesType: SmartDashesType.disabled,
                    style: mono,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Value',
                    ),
                    onChanged: (_) => _emit(),
                  ),
          ),
          SizedBox(
            width: _removeWidth,
            child: Visibility.maintain(
              visible: !isLast,
              child: IconButton(
                key: Key('form-remove-$index'),
                tooltip: 'Remove',
                iconSize: 16,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: isLast
                    ? null
                    : () {
                        setState(() => _rows.removeAt(index).dispose());
                        _emit();
                      },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
