/// Asking before a collection from elsewhere runs scripts or reads files.
library;

import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// What to do about a collection that has not been reviewed yet.
enum ReviewChoice {
  /// Run its scripts and read its files, now and from now on.
  allow,

  /// Send without its scripts this time, and ask again next time.
  skip,

  /// Do not send.
  cancel,
}

/// One request's scripts, with where it is in its collection.
typedef CollectionScript = ({String path, String before, String after});

/// A file one of a collection's requests reads from disk.
typedef CollectionFile = ({String path, String file});

extension CollectionReview on Collection {
  /// Every request in the collection that carries a script.
  List<CollectionScript> get scripts => [
    for (final (path, request) in _requests)
      if (hasScripts(request))
        (
          path: path,
          before: request.preScript ?? '',
          after: request.postScript ?? '',
        ),
  ];

  /// Every file the collection's requests read from disk.
  List<CollectionFile> get files => [
    for (final (path, request) in _requests)
      for (final file in filesRead(request)) (path: path, file: file),
  ];

  List<(String, Request)> get _requests {
    final out = <(String, Request)>[];
    void walk(List<Item> items, String prefix) {
      for (final item in items) {
        final path = prefix.isEmpty ? item.name : '$prefix / ${item.name}';
        if (item.request case final request?) out.add((path, request));
        walk(item.items, path);
      }
    }

    walk(items, '');
    return out;
  }
}

/// Whether [request] carries a script of either kind.
bool hasScripts(Request request) =>
    (request.preScript?.trim().isNotEmpty ?? false) ||
    (request.postScript?.trim().isNotEmpty ?? false);

/// The files [request] reads from disk to send.
List<String> filesRead(Request request) => switch (request.bodyMode) {
  BodyMode.binary => [
    if (request.body case final path? when path.trim().isNotEmpty) path,
  ],
  BodyMode.formData => [
    for (final field in request.form)
      if (field.file) field.value,
  ],
  _ => const [],
};

/// Whether sending [request] has anything a review is about.
bool needsReview(Request request) =>
    hasScripts(request) || filesRead(request).isNotEmpty;

/// [request] with its scripts left out.
Request withoutScripts(Request request) => Request(
  method: request.method,
  url: request.url,
  headers: request.headers,
  body: request.body,
  timeoutMs: request.timeoutMs,
  auth: request.auth,
  settings: request.settings,
  bodyMode: request.bodyMode,
  form: request.form,
  grpcMethod: request.grpcMethod,
  protoPath: request.protoPath,
  graphqlVariables: request.graphqlVariables,
  graphqlOperation: request.graphqlOperation,
  tests: request.tests,
  captures: request.captures,
);

/// Whether sending from [collection] has to ask first: it came from
/// elsewhere with scripts or files, and has not been allowed.
bool needsConsent(WorkspaceStore store, int collection) =>
    collection >= 0 &&
    collection < store.collections.length &&
    store.collections[collection].unreviewed;

/// Shows what the collection at [index] would run and read, and asks
/// whether to go ahead. Allowing it is remembered.
Future<ReviewChoice> askToReview(
  BuildContext context,
  WorkspaceStore store,
  int index,
) async {
  final collection = store.collections[index];
  final scripts = collection.scripts;
  final files = collection.files;
  final choice = await showDialog<ReviewChoice>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final code = mono.copyWith(fontSize: 12);
      final what = [
        if (scripts.isNotEmpty) 'scripts that run each time a request is sent',
        if (files.isNotEmpty) 'files it reads from this machine and sends',
      ].join(', and ');
      final danger = scripts.isEmpty
          ? ''
          : 'Scripts can read every variable, credentials included, and put '
                'them into a request. ';
      return AlertDialog(
        key: const Key('collection-review'),
        title: const Text('Review this collection'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '“${collection.name}” came from elsewhere with $what. '
                '${danger}Allow them only if you trust where it came from.',
              ),
              const SizedBox(height: 12),
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (files.isNotEmpty) ...[
                        Text('Files', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 4),
                        for (final file in files)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: SelectableText.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: file.file,
                                    style: code.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  TextSpan(text: '   ${file.path}'),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                      ],
                      for (final script in scripts) ...[
                        Text(script.path, style: theme.textTheme.labelLarge),
                        for (final (label, text) in [
                          ('Before', script.before),
                          ('After', script.after),
                        ])
                          if (text.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4, bottom: 8),
                              child: SelectableText(
                                '// $label the request\n$text',
                                style: code,
                              ),
                            ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('review-cancel'),
            onPressed: () => Navigator.pop(context, ReviewChoice.cancel),
            child: const Text('Cancel'),
          ),
          // Leaving the scripts out does nothing about the files.
          if (files.isEmpty)
            TextButton(
              key: const Key('review-skip'),
              onPressed: () => Navigator.pop(context, ReviewChoice.skip),
              child: const Text('Send without scripts'),
            ),
          FilledButton(
            key: const Key('review-allow'),
            onPressed: () => Navigator.pop(context, ReviewChoice.allow),
            child: const Text('Allow and send'),
          ),
        ],
      );
    },
  );
  if (choice == ReviewChoice.allow) store.markReviewed(index);
  return choice ?? ReviewChoice.cancel;
}
