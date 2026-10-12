import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide FormField;

import 'key_value_editor.dart';
import 'src/rust/api/core.dart';

const _mono = TextStyle(fontFamily: 'Menlo', fontSize: 13, height: 1.4);

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
};

/// Asks for a file and returns its path, or null when cancelled.
Future<String?> _pickPath() async => (await FilePicker.pickFile())?.path;

/// The Body tab: a body type picker and the editor for that type.
/// The page owns all the state, so switching type loses nothing.
class BodyEditor extends StatelessWidget {
  const BodyEditor({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.raw,
    required this.rawLanguage,
    required this.onRawLanguageChanged,
    required this.urlEncoded,
    required this.urlEncodedBulk,
    required this.onUrlEncodedBulkChanged,
    required this.formData,
    required this.binary,
  });

  final BodyMode mode;
  final ValueChanged<BodyMode> onModeChanged;

  final TextEditingController raw;

  /// The name from [rawLanguages] matching the Content-Type header, if any.
  final String? rawLanguage;
  final ValueChanged<String> onRawLanguageChanged;

  /// Url-encoded fields as `key: value` lines.
  final TextEditingController urlEncoded;
  final bool urlEncodedBulk;
  final ValueChanged<bool> onUrlEncodedBulkChanged;

  /// The form-data table, which keeps its own rows.
  final Widget formData;

  /// Path of the file to send as the body.
  final TextEditingController binary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in _modeLabels.entries)
                ChoiceChip(
                  key: Key('body-mode-${entry.value}'),
                  label: Text(entry.value),
                  selected: mode == entry.key,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => onModeChanged(entry.key),
                ),
              if (mode == BodyMode.raw)
                DropdownButton<String>(
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
            ],
          ),
        ),
        Expanded(
          child: switch (mode) {
            BodyMode.none => Center(
              child: Text(
                'This request does not have a body',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            BodyMode.raw => TextField(
              key: const Key('body'),
              controller: raw,
              maxLines: null,
              expands: true,
              autocorrect: false,
              enableSuggestions: false,
              smartQuotesType: SmartQuotesType.disabled,
              smartDashesType: SmartDashesType.disabled,
              textAlignVertical: TextAlignVertical.top,
              style: _mono,
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(12),
                hintText: '{\n  "name": "reqorb"\n}',
              ),
            ),
            BodyMode.urlEncoded => KeyValueEditor(
              controller: urlEncoded,
              name: 'urlencoded',
              bulk: urlEncodedBulk,
              onBulkChanged: onUrlEncodedBulkChanged,
              bulkHint: 'username: alice\ngrant_type: password',
            ),
            BodyMode.formData => formData,
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
      style: _mono,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        hintText: hint,
        suffixIcon: IconButton(
          key: browseKey,
          tooltip: 'Choose file',
          iconSize: 18,
          icon: const Icon(Icons.folder_open_outlined),
          onPressed: () async {
            final path = await _pickPath();
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
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
            flex: 2,
            child: TextField(
              key: Key('form-key-$index'),
              controller: row.key,
              autocorrect: false,
              enableSuggestions: false,
              smartQuotesType: SmartQuotesType.disabled,
              smartDashesType: SmartDashesType.disabled,
              style: _mono,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText: 'Key',
              ),
              onChanged: (_) => _emit(),
            ),
          ),
          const SizedBox(width: 6),
          DropdownButton<bool>(
            key: Key('form-type-$index'),
            value: row.file,
            isDense: true,
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
                    style: _mono,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      hintText: 'Value',
                    ),
                    onChanged: (_) => _emit(),
                  ),
          ),
          Visibility.maintain(
            visible: !isLast,
            child: IconButton(
              key: Key('form-remove-$index'),
              tooltip: 'Remove',
              iconSize: 18,
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
        ],
      ),
    );
  }
}
