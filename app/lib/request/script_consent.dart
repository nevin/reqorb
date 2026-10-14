/// Asking before scripts that came from elsewhere run for the first time.
library;

import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// What to do about a collection's scripts that have not been allowed yet.
enum ScriptChoice {
  /// Run them, now and from now on.
  allow,

  /// Send without them this time, and ask again next time.
  skip,

  /// Do not send.
  cancel,
}

/// One request's scripts, with where it is in its collection.
typedef CollectionScript = ({String path, String before, String after});

extension CollectionScripts on Collection {
  /// Every request in the collection that carries a script.
  List<CollectionScript> get scripts {
    final out = <CollectionScript>[];
    void walk(List<Item> items, String prefix) {
      for (final item in items) {
        final path = prefix.isEmpty ? item.name : '$prefix / ${item.name}';
        final request = item.request;
        if (request != null && hasScripts(request)) {
          out.add((
            path: path,
            before: request.preScript ?? '',
            after: request.postScript ?? '',
          ));
        }
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

/// Whether sending a request from [collection] has to ask first: it has
/// scripts that came from elsewhere and have not been allowed.
bool needsConsent(WorkspaceStore store, int collection) =>
    collection >= 0 &&
    collection < store.collections.length &&
    store.collections[collection].untrustedScripts;

/// Asks whether the scripts of the collection at [index] may run, showing
/// them so they can be read first. Allowing them is remembered.
Future<ScriptChoice> askToRunScripts(
  BuildContext context,
  WorkspaceStore store,
  int index,
) async {
  final collection = store.collections[index];
  final scripts = collection.scripts;
  final choice = await showDialog<ScriptChoice>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        key: const Key('script-consent'),
        title: const Text('Run this collection’s scripts?'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '“${collection.name}” came with scripts that run each time '
                'one of its requests is sent. They can read every variable, '
                'credentials included, and put them into the request. Allow '
                'them only if you trust where the collection came from.',
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
                                style: mono.copyWith(fontSize: 12),
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
            key: const Key('scripts-cancel'),
            onPressed: () => Navigator.pop(context, ScriptChoice.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('scripts-skip'),
            onPressed: () => Navigator.pop(context, ScriptChoice.skip),
            child: const Text('Send without scripts'),
          ),
          FilledButton(
            key: const Key('scripts-allow'),
            onPressed: () => Navigator.pop(context, ScriptChoice.allow),
            child: const Text('Allow and send'),
          ),
        ],
      );
    },
  );
  if (choice == ScriptChoice.allow) store.trustScripts(index);
  return choice ?? ScriptChoice.cancel;
}
