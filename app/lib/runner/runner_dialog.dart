/// Running a collection or a folder and showing how each request came out.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/runner/collection_run.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// A data file's name and what it holds.
typedef DataFile = ({String name, String text});

Future<DataFile?> _pickDataFile() async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;
  return (
    name: file.name,
    text: utf8.decode(await file.readAsBytes(), allowMalformed: true),
  );
}

/// Opens the runner for [steps], the requests of the collection or folder
/// called [name].
Future<void> showRunner(
  BuildContext context, {
  required WorkspaceStore store,
  required String name,
  required List<RunStep> steps,
  Future<DataFile?> Function() pickData = _pickDataFile,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      RunnerDialog(store: store, name: name, steps: steps, pickData: pickData),
);

class RunnerDialog extends StatefulWidget {
  const RunnerDialog({
    super.key,
    required this.store,
    required this.name,
    required this.steps,
    this.pickData = _pickDataFile,
  });

  final WorkspaceStore store;
  final String name;
  final List<RunStep> steps;

  /// Asks for the data file; replaced in tests, which have no file dialog.
  final Future<DataFile?> Function() pickData;

  @override
  State<RunnerDialog> createState() => _RunnerDialogState();
}

class _RunnerDialogState extends State<RunnerDialog> {
  late final CollectionRun _run = CollectionRun(
    Engine.of(context),
    widget.store,
  )..addListener(_changed);
  late final List<bool> _chosen = [
    for (final step in widget.steps) step.runnable,
  ];
  final _iterations = TextEditingController(text: '1');
  final _delay = TextEditingController(text: '0');
  bool _stopOnFailure = false;

  String? _dataName;
  List<List<Variable>>? _rows;
  String? _dataError;

  /// Whether a run has been started, which swaps the list of requests for
  /// the list of results.
  bool _started = false;

  void _changed() => setState(() {});

  @override
  void dispose() {
    _run
      ..removeListener(_changed)
      ..dispose();
    _iterations.dispose();
    _delay.dispose();
    super.dispose();
  }

  List<RunStep> get _selected => [
    for (final (i, step) in widget.steps.indexed)
      if (_chosen[i]) step,
  ];

  int get _times {
    final typed = int.tryParse(_iterations.text.trim()) ?? 1;
    final times = typed < 1 ? 1 : typed;
    final rows = _rows;
    return rows == null ? times : (times < rows.length ? times : rows.length);
  }

  Future<void> _chooseData() async {
    try {
      final file = await widget.pickData();
      if (file == null || !mounted) return;
      final rows = Engine.of(context)
          .parseRunData(name: file.name, text: file.text);
      setState(() {
        _dataName = file.name;
        _rows = rows;
        _dataError = null;
        // A data file is gone through to its end unless told otherwise.
        _iterations.text = '${rows.length}';
      });
    } catch (e) {
      if (mounted) setState(() => _dataError = '$e');
    }
  }

  void _clearData() => setState(() {
    _dataName = null;
    _rows = null;
    _dataError = null;
    _iterations.text = '1';
  });

  void _start() {
    final rows = _rows;
    final times = _times;
    setState(() => _started = true);
    _run.start(
      _selected,
      rows: rows == null
          ? List.filled(times, const <Variable>[])
          : rows.sublist(0, times),
      delay: Duration(milliseconds: int.tryParse(_delay.text.trim()) ?? 0),
      stopOnFailure: _stopOnFailure,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final selected = _selected.length;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      title: Text('Run ${widget.name}', maxLines: 1, overflow: .ellipsis),
      content: SizedBox(
        width: (size.width - 120).clamp(320.0, 760.0),
        height: (size.height - 260).clamp(240.0, 620.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _options(context),
            const SizedBox(height: 8),
            if (_started) _summary(context),
            const Divider(height: 16),
            Expanded(child: _started ? _results(context) : _requests(context)),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('run-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (_run.running)
          FilledButton.tonal(
            key: const Key('run-stop'),
            onPressed: _run.stopping ? null : _run.stop,
            child: Text(_run.stopping ? 'Stopping…' : 'Stop'),
          )
        else
          FilledButton(
            key: const Key('run-start'),
            onPressed: selected == 0 ? null : _start,
            child: Text(
              _started
                  ? 'Run again'
                  : 'Run $selected request${selected == 1 ? '' : 's'}',
            ),
          ),
      ],
    );
  }

  Widget _options(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _run.running;
    Widget number(String label, Key key, TextEditingController controller) =>
        SizedBox(
          width: 110,
          child: TextField(
            key: key,
            controller: controller,
            enabled: !busy,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        );
    final rows = _rows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            number('Iterations', const Key('run-iterations'), _iterations),
            number('Delay (ms)', const Key('run-delay'), _delay),
            OutlinedButton.icon(
              key: const Key('run-data'),
              onPressed: busy ? null : _chooseData,
              icon: const Icon(Icons.table_rows_outlined, size: 18),
              label: Text(
                rows == null
                    ? 'Data file…'
                    : '$_dataName · ${rows.length} row${rows.length == 1 ? '' : 's'}',
              ),
            ),
            if (rows != null)
              IconButton(
                key: const Key('run-data-clear'),
                tooltip: 'Run without the data file',
                onPressed: busy ? null : _clearData,
                icon: const Icon(Icons.close, size: 18),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  key: const Key('run-bail'),
                  value: _stopOnFailure,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => _stopOnFailure = v ?? false),
                ),
                const Text('Stop at the first failure'),
              ],
            ),
          ],
        ),
        if (_dataError case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error,
              key: const Key('run-data-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          )
        else if (rows != null && rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Each iteration sets ${rows.first.map((v) => '{{${v.key}}}').join(', ')}'
              ' from one row.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  /// Before a run: what will be sent, each of which can be left out.
  Widget _requests(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.steps.isEmpty) {
      return const Center(child: Text('There are no requests here to run.'));
    }
    return ListView.builder(
      itemCount: widget.steps.length,
      itemBuilder: (context, i) {
        final step = widget.steps[i];
        return CheckboxListTile(
          key: Key('run-step-$i'),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: _chosen[i],
          onChanged: step.runnable
              ? (v) => setState(() => _chosen[i] = v ?? false)
              : null,
          title: Row(
            children: [
              _Method(step.request.method),
              const SizedBox(width: 8),
              Expanded(
                child: Text(step.path, maxLines: 1, overflow: .ellipsis),
              ),
            ],
          ),
          subtitle: step.runnable
              ? null
              : Text(
                  'A run cannot hold a ${step.request.method == 'WS' ? 'WebSocket' : 'gRPC'} conversation',
                  style: theme.textTheme.bodySmall,
                ),
        );
      },
    );
  }

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    final done = _run.results.length;
    final failed = _run.failed;
    final seconds = (_run.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    final parts = [
      _run.running ? '$done of ${_run.planned}' : '$done run',
      '$failed failed',
      if (_run.tests > 0) '${_run.tests} tests, ${_run.testsFailed} failed',
      '$seconds s',
      if (_run.endedEarly case final why? when !_run.running) why,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: _run.planned == 0 ? 0 : done / _run.planned,
          color: failed > 0 ? theme.colorScheme.error : null,
        ),
        const SizedBox(height: 8),
        Text(
          parts.join(' · '),
          key: const Key('run-summary'),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: failed > 0 ? theme.colorScheme.error : null,
          ),
        ),
      ],
    );
  }

  Widget _results(BuildContext context) {
    final results = _run.results;
    final several = _run.planned > _selected.length;
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, i) {
        final result = results[i];
        final first = i == 0 || results[i - 1].iteration != result.iteration;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (several && first)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                child: Text(
                  'Iteration ${result.iteration + 1}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            _ResultTile(key: Key('run-result-$i'), result: result),
          ],
        );
      },
    );
  }
}

class _Method extends StatelessWidget {
  const _Method(this.method);

  final String method;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 56,
    child: Text(
      method,
      maxLines: 1,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: methodColor(method, Theme.of(context).brightness),
      ),
    ),
  );
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({super.key, required this.result});

  final RunResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sent = result.sent;
    final passed = result.passed;
    final small = theme.textTheme.bodySmall;
    final mono = small?.copyWith(fontFamily: 'Menlo');
    final details = <Widget>[
      if (result.error case final error?)
        Text(error, style: small?.copyWith(color: scheme.error)),
      if (sent != null) ...[
        for (final name in sent.unresolved)
          Text('{{$name}} has no value', style: small),
        for (final test in sent.tests)
          Text(
            '${test.passed ? '✓' : '✗'} ${test.test}'
            '${test.detail.isEmpty ? '' : '  (${test.detail})'}',
            style: mono?.copyWith(color: test.passed ? null : scheme.error),
          ),
        for (final problem in sent.captureProblems)
          Text(problem, style: small?.copyWith(color: scheme.error)),
        for (final error in sent.graphqlErrors)
          Text(error, style: small?.copyWith(color: scheme.error)),
        for (final variable in sent.captured)
          Text('${variable.key} = ${variable.value}', style: mono),
        if (!passed && sent.response.body.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              sent.response.body.length > 600
                  ? '${sent.response.body.substring(0, 600)}…'
                  : sent.response.body,
              style: mono?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    ];
    return ExpansionTile(
      dense: true,
      shape: const Border(),
      collapsedShape: const Border(),
      // What went wrong is the reason to look, so it is already open.
      initiallyExpanded: !passed,
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: const EdgeInsets.fromLTRB(36, 0, 8, 10),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      expandedAlignment: Alignment.centerLeft,
      leading: Icon(
        passed ? Icons.check_circle : Icons.cancel,
        size: 18,
        color: passed ? statusColor(200, scheme) : scheme.error,
      ),
      title: Row(
        children: [
          _Method(result.step.request.method),
          const SizedBox(width: 8),
          Expanded(
            child: Text(result.step.path, maxLines: 1, overflow: .ellipsis),
          ),
          if (sent != null) ...[
            if (sent.tests.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  '${sent.tests.length - result.testsFailed}/${sent.tests.length} tests',
                  style: small,
                ),
              ),
            Text(
              '${sent.response.status} ${sent.response.statusText}',
              style: small?.copyWith(
                fontWeight: FontWeight.w600,
                color: statusColor(sent.response.status, scheme),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 64,
              child: Text(
                '${sent.response.elapsedMs} ms',
                textAlign: TextAlign.right,
                style: small,
              ),
            ),
          ] else
            Text('No response', style: small?.copyWith(color: scheme.error)),
        ],
      ),
      children: details.isEmpty
          ? [Text('Nothing to report.', style: small)]
          : details,
    );
  }
}
