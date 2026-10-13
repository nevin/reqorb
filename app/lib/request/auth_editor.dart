import 'package:flutter/material.dart';

import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/shared/theme.dart';

/// The Auth tab: a type picker and the form that type needs.
///
/// The form is generated from the fields the core reports for each type, so
/// a new auth type needs no changes here. Give the widget a new [key] to
/// load a different request's auth.
class AuthEditor extends StatefulWidget {
  const AuthEditor({super.key, required this.auth, required this.onChanged});

  final Auth? auth;

  /// Called with null when the type is set to "No Auth".
  final ValueChanged<Auth?> onChanged;

  @override
  State<AuthEditor> createState() => _AuthEditorState();
}

class _AuthEditorState extends State<AuthEditor> {
  static final _choices = authChoices();

  late AuthKind _kind = widget.auth?.kind ?? AuthKind.none;
  late List<AuthField> _fields = authFields(kind: _kind);
  final _controllers = <String, TextEditingController>{};
  final _selected = <String, String>{};
  final _revealed = <String>{};

  /// Parameters with no field on the form, typically from an import; they
  /// are kept so that editing one field does not drop them.
  var _extra = <AuthParam>[];

  @override
  void initState() {
    super.initState();
    _load(widget.auth?.params ?? const []);
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void _disposeControllers() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }

  void _load(List<AuthParam> params) {
    _disposeControllers();
    _selected.clear();
    _revealed.clear();
    final values = {for (final p in params) p.key: p.value};
    for (final field in _fields) {
      final value = values.remove(field.key) ?? '';
      if (field.options.isEmpty) {
        _controllers[field.key] = TextEditingController(text: value);
      } else {
        _selected[field.key] = field.options.contains(value)
            ? value
            : field.defaultValue;
      }
    }
    _extra = [
      for (final p in params)
        if (values.containsKey(p.key)) p,
    ];
  }

  void _setKind(AuthKind kind) {
    setState(() {
      _kind = kind;
      _fields = authFields(kind: kind);
      _load(const []);
    });
    _emit();
  }

  void _emit() {
    if (_kind == AuthKind.none) {
      widget.onChanged(null);
      return;
    }
    widget.onChanged(
      Auth(
        kind: _kind,
        params: [
          for (final field in _fields)
            if (field.options.isNotEmpty)
              AuthParam(key: field.key, value: _selected[field.key]!)
            else if (_controllers[field.key]!.text.isNotEmpty)
              AuthParam(key: field.key, value: _controllers[field.key]!.text),
          ..._extra,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A plain column, not a lazy list: the forms are short, and every field
    // should exist even while scrolled out of view.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<AuthKind>(
            key: const Key('auth-kind'),
            initialValue: _kind,
            decoration: const InputDecoration(
              labelText: 'Type',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final choice in _choices)
                DropdownMenuItem(value: choice.kind, child: Text(choice.label)),
            ],
            onChanged: (kind) => _setKind(kind ?? _kind),
          ),
          if (_kind == AuthKind.none)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                'This request is sent without authorization. '
                'Field values can use {{variables}}.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          for (final field in _fields)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: field.options.isEmpty ? _text(field) : _choice(field),
            ),
        ],
      ),
    );
  }

  Widget _choice(AuthField field) {
    return DropdownButtonFormField<String>(
      // Rebuilt when the type changes, so a stale selection cannot linger.
      key: Key('auth-${field.key}'),
      initialValue: _selected[field.key],
      decoration: InputDecoration(
        labelText: field.label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final option in field.options)
          DropdownMenuItem(value: option, child: Text(option)),
      ],
      onChanged: (value) {
        setState(() => _selected[field.key] = value ?? field.defaultValue);
        _emit();
      },
    );
  }

  Widget _text(AuthField field) {
    // Multi-line fields, such as a PEM key, cannot be masked.
    final maskable = field.secret && !field.multiline;
    final hidden = maskable && !_revealed.contains(field.key);
    return TextField(
      key: Key('auth-${field.key}'),
      controller: _controllers[field.key],
      obscureText: hidden,
      minLines: field.multiline ? 3 : 1,
      maxLines: field.multiline ? 8 : 1,
      autocorrect: false,
      enableSuggestions: false,
      smartQuotesType: SmartQuotesType.disabled,
      smartDashesType: SmartDashesType.disabled,
      style: mono,
      decoration: InputDecoration(
        labelText: field.label,
        alignLabelWithHint: true,
        hintText: field.hint.isNotEmpty
            ? field.hint
            : (field.defaultValue.isEmpty ? null : field.defaultValue),
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: maskable
            ? IconButton(
                tooltip: hidden ? 'Show' : 'Hide',
                icon: Icon(
                  hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() {
                  if (!_revealed.remove(field.key)) _revealed.add(field.key);
                }),
              )
            : null,
      ),
      onChanged: (_) => _emit(),
    );
  }
}
