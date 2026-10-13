/// Naming collections and requests.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reqorb/shared/folders.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/shared/text_dialog.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// Asks for a new name for a saved request; null when cancelled or empty.
Future<String?> askRequestName(BuildContext context, String current) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => TextDialog(
      title: 'Rename request',
      action: 'Rename',
      fieldKey: const Key('request-name'),
      hint: 'Request name',
      lines: 1,
      initial: current,
      url: false,
    ),
  );
  return (name == null || name.trim().isEmpty) ? null : name.trim();
}

/// Asks for a collection name; null when cancelled or left empty.
Future<String?> askCollectionName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => TextDialog(
      title: title,
      action: action,
      fieldKey: const Key('collection-name'),
      hint: 'Collection name',
      lines: 1,
      initial: initial,
      url: false,
    ),
  );
  return (name == null || name.trim().isEmpty) ? null : name.trim();
}

Future<void> newCollection(BuildContext context, WorkspaceStore store) async {
  final name = await askCollectionName(
    context,
    title: 'New collection',
    action: 'Create',
  );
  if (name != null) store.addCollection(name);
}

Future<void> renameCollection(
  BuildContext context,
  WorkspaceStore store,
  int index,
) async {
  final collection = store.collections[index];
  final name = await askCollectionName(
    context,
    title: 'Rename collection',
    action: 'Rename',
    initial: collection.name,
  );
  // Look the collection up again in case the list changed meanwhile.
  final current = store.collections.indexOf(collection);
  if (name != null && current >= 0) store.renameCollection(current, name);
}

/// Asks for a folder and keeps the collection at [index] there from now
/// on, one file for each request.
Future<void> keepInFolder(
  BuildContext context,
  WorkspaceStore store,
  int index,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final name = store.collections[index].name;
  final path = await folders.choose(title: 'Choose a folder for $name');
  if (path == null) return;
  final grant = await folders.grant(path);
  final problem = await store.linkCollection(index, path, grant);
  notify(
    messenger,
    problem ?? '$name is now kept in $path, one file for each request',
  );
}

/// Asks for a folder that holds a collection, and opens it.
Future<void> openCollectionFolder(
  BuildContext context,
  WorkspaceStore store,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final path = await folders.choose(title: 'Open a collection folder');
  if (path == null) return;
  final grant = await folders.grant(path);
  final problem = await store.openCollectionDir(path, grant);
  if (problem != null) notify(messenger, problem);
}

/// Reads the collection at [index] again from its folder.
Future<void> reloadFromFolder(
  BuildContext context,
  WorkspaceStore store,
  int index,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final name = store.collections[index].name;
  final problem = await store.reloadCollection(index);
  notify(messenger, problem ?? '$name was read again from its folder');
}
