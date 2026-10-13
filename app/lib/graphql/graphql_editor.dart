import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/graphql/graphql_complete.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/src/rust/api/core.dart';

/// Why [text] cannot be sent as GraphQL variables, or null when it can.
/// Text with `{{variables}}` in it is judged once they are filled in.
String? variablesProblem(String text) {
  if (text.trim().isEmpty || text.contains('{{')) return null;
  try {
    return jsonDecode(text) is Map
        ? null
        : 'Variables must be a JSON object, such as {"id": 1}';
  } on FormatException {
    return 'Variables are not valid JSON';
  }
}

/// The GraphQL body: a query, its variables, and the server's schema to
/// write them from.
class GraphqlEditor extends StatelessWidget {
  const GraphqlEditor({
    super.key,
    required this.query,
    required this.variables,
    required this.operation,
    required this.onOperationChanged,
    required this.schema,
    this.variableNames = const [],
    required this.loadingSchema,
    required this.schemaError,
    required this.onSchema,
    required this.onRefreshSchema,
  });

  final CodeController query;
  final CodeController variables;

  /// Which of the query's operations is sent; empty for the only one.
  final String operation;
  final ValueChanged<String> onOperationChanged;

  /// The server's schema, once it has been fetched. Fields and arguments
  /// are completed from it.
  final GraphQlSchema? schema;

  /// Names of the variables in reach, offered after `{{`.
  final List<String> variableNames;
  final bool loadingSchema;

  /// Why the schema could not be fetched, when that was tried and failed.
  final String? schemaError;

  /// Shows the schema, fetching it first if need be.
  final VoidCallback onSchema;
  final VoidCallback onRefreshSchema;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final engine = Engine.of(context);
    final small = theme.textTheme.bodySmall;
    final hasSchema = schema != null;
    return ListenableBuilder(
      listenable: Listenable.merge([query, variables]),
      builder: (context, _) {
        final found = engine.graphqlInspect(query: query.text);
        final operations = found.operations;
        // A name that is no longer in the query cannot be asked for.
        final chosen = operations.contains(operation) ? operation : null;
        final badVariables = variablesProblem(variables.text);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    key: const Key('graphql-schema'),
                    onPressed: loadingSchema ? null : onSchema,
                    icon: loadingSchema
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.account_tree_outlined, size: 16),
                    label: Text(hasSchema ? 'Schema' : 'Fetch schema'),
                  ),
                  if (hasSchema)
                    IconButton(
                      key: const Key('graphql-schema-refresh'),
                      tooltip: 'Fetch the schema again',
                      iconSize: 18,
                      onPressed: loadingSchema ? null : onRefreshSchema,
                      icon: const Icon(Icons.refresh),
                    ),
                  const SizedBox(width: 4),
                  if (operations.length > 1)
                    Flexible(
                      // Expanded inside a cap, so a long name is cut short
                      // rather than pushed out of a narrow pane.
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: DropdownButton<String>(
                          key: const Key('graphql-operation'),
                          value: chosen,
                          hint: const Text('Operation'),
                          isDense: true,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final name in operations)
                              DropdownMenuItem(
                                value: name,
                                child: Text(
                                  name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (name) => onOperationChanged(name ?? ''),
                        ),
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    key: const Key('graphql-format'),
                    tooltip: 'Format the query',
                    iconSize: 18,
                    onPressed: query.text.trim().isEmpty
                        ? null
                        : () {
                            try {
                              query.text = engine.graphqlFormat(
                                query: query.text,
                              );
                            } catch (e) {
                              showMessage(context, '$e');
                            }
                          },
                    icon: const Icon(Icons.format_align_left),
                  ),
                ],
              ),
            ),
            if (schemaError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Text(
                  error,
                  key: const Key('graphql-schema-error'),
                  style: small?.copyWith(color: scheme.error),
                ),
              ),
            Expanded(
              flex: 3,
              child: CodeEditor(
                name: 'graphql-query',
                controller: query,
                language: CodeLanguage.graphql,
                variables: variableNames,
                complete: schema == null
                    ? null
                    : (text, caret, {required asked}) =>
                          completeGraphql(schema!, text, caret, asked: asked),
                hint: 'query { user(id: 1) { name } }',
              ),
            ),
            if (found.problem.isNotEmpty ||
                (operations.length > 1 && chosen == null))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(
                  found.problem.isNotEmpty
                      ? found.problem
                      : 'Choose which operation to run',
                  key: const Key('graphql-problem'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(color: scheme.error),
                ),
              ),
            Divider(color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                spacing: 8,
                children: [
                  Text('Variables', style: theme.textTheme.labelMedium),
                  if (badVariables != null)
                    Flexible(
                      child: Text(
                        badVariables,
                        key: const Key('graphql-variables-problem'),
                        overflow: TextOverflow.ellipsis,
                        style: small?.copyWith(color: scheme.error),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: CodeEditor(
                name: 'graphql-variables',
                controller: variables,
                language: CodeLanguage.json,
                variables: variableNames,
                hint: '{ "id": {{userId}} }',
              ),
            ),
          ],
        );
      },
    );
  }
}
