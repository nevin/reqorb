/// Opening the analysis of a HAR file or of the session.
library;

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/har/har_analysis.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/transfer/import_actions.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// Lets the user pick a HAR file and opens a report on it.
Future<void> analyzeHarFile(BuildContext context, WorkspaceStore store) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    if (!context.mounted) return;
    await showHarAnalysis(context, store, name: file.name, text: text);
  } catch (e) {
    notify(messenger, 'Could not read the file: $e');
  }
}

/// Opens a report on the requests sent in this session.
Future<void> analyzeSession(BuildContext context, WorkspaceStore store) =>
    showHarAnalysis(
      context,
      store,
      name: 'Session',
      text: Engine.of(context).exportHar(exchanges: store.session),
    );

/// Analyses [text], a HAR archive called [name], and shows the report.
Future<void> showHarAnalysis(
  BuildContext context,
  WorkspaceStore store, {
  required String name,
  required String text,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final engine = Engine.of(context);
  final HarReport report;
  try {
    report = await engine.analyzeHar(text: text);
  } catch (e) {
    notify(messenger, 'Could not analyse $name: $e');
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => HarAnalysisPage(
        name: name,
        report: report,
        onImport: (context, entries) => runImport(
          context,
          store,
          () => engine.importHar(
            text: text,
            name: nameHintFor(name),
            entries: entries,
          ),
        ),
      ),
    ),
  );
}
