/// A request written out as code, to copy into a program or a terminal.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/transfer/export_actions.dart';

/// The language last chosen, offered again the next time.
CodeTarget _last = CodeTarget.curl;

/// How code for [target] is coloured.
CodeLanguage codeLanguageOf(CodeTarget target) => switch (target) {
  CodeTarget.fetch ||
  CodeTarget.axios ||
  CodeTarget.typeScript => CodeLanguage.javascript,
  CodeTarget.curl ||
  CodeTarget.python ||
  CodeTarget.ruby ||
  CodeTarget.powerShell => CodeLanguage.script,
  _ => CodeLanguage.source,
};

/// Shows [request] as code, in a language chosen there. [variables] are
/// filled in, so that what is copied runs as it stands.
Future<void> showCodeDialog(
  BuildContext context, {
  required Request request,
  required List<Variable> variables,
  String name = '',
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      CodeDialog(request: request, variables: variables, name: name),
);

class CodeDialog extends StatefulWidget {
  const CodeDialog({
    super.key,
    required this.request,
    required this.variables,
    this.name = '',
  });

  final Request request;
  final List<Variable> variables;

  /// What the request is called, for the name of a saved file.
  final String name;

  @override
  State<CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<CodeDialog> {
  late final Engine _engine = Engine.of(context);
  late final List<CodeChoice> _choices = _engine.codeChoices();
  late CodeTarget _target = _choices.any((c) => c.target == _last)
      ? _last
      : _choices.first.target;
  String _code = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _write();
  }

  void _write() {
    try {
      _code = _engine.generateCode(
        request: widget.request,
        variables: widget.variables,
        target: _target,
      );
      _error = null;
    } catch (e) {
      _code = '';
      _error = '$e';
    }
  }

  void _choose(CodeTarget? target) {
    if (target == null) return;
    setState(() {
      _target = _last = target;
      _write();
    });
  }

  /// The code as it is looked at: a tab is given the width it has in an
  /// editor, which a text field would not give it.
  String get _shown => _code.trimRight().replaceAll('\t', '    ');

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    // Without the last line break, which would run a command the moment
    // it is pasted into a terminal.
    await Clipboard.setData(ClipboardData(text: _code.trimRight()));
    notify(messenger, 'Code copied');
  }

  Future<void> _save() {
    final choice = _choices.firstWhere((c) => c.target == _target);
    final base = widget.name.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9._-]+'),
      '-',
    );
    return saveCodeFile(
      context,
      '${base.isEmpty ? 'request' : base}.${choice.fileExtension}',
      _code,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final error = _error;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      title: Row(
        children: [
          const Expanded(child: Text('Code')),
          DropdownButton<CodeTarget>(
            key: const Key('code-language'),
            value: _target,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(8),
            items: [
              for (final choice in _choices)
                DropdownMenuItem(
                  value: choice.target,
                  child: Text(choice.label),
                ),
            ],
            onChanged: _choose,
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: (size.height - 260).clamp(160.0, 520.0),
        child: error != null
            ? Center(
                child: Text(
                  error,
                  key: const Key('code-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              )
            : DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CodeView(
                    // A view of its own for each language, scrolled to the top.
                    key: ValueKey(_target),
                    name: 'generated-code',
                    text: _shown,
                    language: codeLanguageOf(_target),
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          key: const Key('code-save'),
          onPressed: error == null ? _save : null,
          child: const Text('Save to file…'),
        ),
        TextButton(
          key: const Key('code-close'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const Key('code-copy'),
          onPressed: error == null ? _copy : null,
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
        ),
      ],
    );
  }
}
