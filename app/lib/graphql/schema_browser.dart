import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';

/// A field of one of the schema's root types, picked to write a query for.
typedef RootField = ({String kind, String field});

/// Shows a GraphQL schema: what can be asked for, and every type by name.
/// Returns the root field chosen to write a query from, if one was.
Future<RootField?> showSchemaBrowser(
  BuildContext context,
  GraphQlSchema schema,
) => showDialog<RootField>(
  context: context,
  builder: (_) => SchemaBrowser(schema: schema),
);

class SchemaBrowser extends StatefulWidget {
  const SchemaBrowser({super.key, required this.schema});

  final GraphQlSchema schema;

  @override
  State<SchemaBrowser> createState() => _SchemaBrowserState();
}

class _SchemaBrowserState extends State<SchemaBrowser> {
  final _search = TextEditingController();

  /// The types opened on the way to the one showing; empty at the start.
  final _trail = <String>[];

  GraphQlSchema get _schema => widget.schema;

  late final _byName = {for (final t in _schema.types) t.name: t};

  /// The root types that exist, with the word a query for one starts with.
  late final _roots = [
    for (final (kind, name) in [
      ('query', _schema.queryType),
      ('mutation', _schema.mutationType),
      ('subscription', _schema.subscriptionType),
    ])
      if (_byName[name] case final type?) (kind: kind, type: type),
  ];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(String type) {
    if (!_byName.containsKey(type)) return;
    setState(() {
      _search.clear();
      _trail.add(type);
    });
  }

  /// The word a query for a field of [type] starts with, when [type] is one
  /// of the root types.
  String? _kindOf(GraphQlType type) =>
      _roots.where((r) => r.type.name == type.name).firstOrNull?.kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final words = _search.text.trim().toLowerCase();
    final current = _trail.isEmpty ? null : _byName[_trail.last];
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('schema-back'),
                    tooltip: 'Back',
                    onPressed: _trail.isEmpty
                        ? null
                        : () => setState(_trail.removeLast),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(
                    child: Text(
                      current?.name ?? 'Schema',
                      key: const Key('schema-title'),
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    key: const Key('schema-close'),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const Key('schema-search'),
                controller: _search,
                autocorrect: false,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search types and fields',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Divider(color: scheme.outlineVariant),
            Expanded(
              child: words.isNotEmpty
                  ? _results(words)
                  : current != null
                  ? _type(current)
                  : _home(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  /// What can be asked for, then every type.
  Widget _home() => ListView(
    children: [
      for (final root in _roots) ...[
        _heading(switch (root.kind) {
          'query' => 'Queries',
          'mutation' => 'Mutations',
          _ => 'Subscriptions',
        }),
        for (final field in root.type.fields)
          _FieldRow(
            field: field,
            owner: root.type.name,
            onOpen: _open,
            onUse: () =>
                Navigator.of(context).pop((kind: root.kind, field: field.name)),
          ),
      ],
      _heading('Types'),
      for (final type in _schema.types)
        if (!_isBuiltIn(type)) _TypeRow(type: type, onOpen: _open),
    ],
  );

  static bool _isBuiltIn(GraphQlType type) =>
      type.kind == 'SCALAR' &&
      const {'String', 'Int', 'Float', 'Boolean', 'ID'}.contains(type.name);

  Widget _type(GraphQlType type) {
    final kind = _kindOf(type);
    return ListView(
      children: [
        _note(
          [
            type.kind.toLowerCase().replaceAll('_', ' '),
            if (type.description.isNotEmpty) type.description,
          ].join(' · '),
        ),
        if (type.members.isNotEmpty) ...[
          _heading(type.kind == 'UNION' ? 'One of' : 'Implemented by'),
          for (final member in type.members)
            if (_byName[member] case final found?)
              _TypeRow(type: found, onOpen: _open),
        ],
        if (type.fields.isNotEmpty)
          _heading(type.kind == 'ENUM' ? 'Values' : 'Fields'),
        for (final field in type.fields)
          _FieldRow(
            field: field,
            owner: type.name,
            onOpen: _open,
            onUse: kind == null
                ? null
                : () =>
                      Navigator.of(context)
                          .pop((kind: kind, field: field.name)),
          ),
      ],
    );
  }

  Widget _results(String words) {
    final types = [
      for (final type in _schema.types)
        if (type.name.toLowerCase().contains(words)) type,
    ];
    final fields = [
      for (final type in _schema.types)
        for (final field in type.fields)
          if (field.name.toLowerCase().contains(words)) (type, field),
    ];
    if (types.isEmpty && fields.isEmpty) {
      return Center(
        child: Text(
          'Nothing in the schema matches',
          key: const Key('schema-no-results'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView(
      children: [
        if (types.isNotEmpty) _heading('Types'),
        for (final type in types) _TypeRow(type: type, onOpen: _open),
        if (fields.isNotEmpty) _heading('Fields'),
        // Enough to show there are more; narrowing the search finds the rest.
        for (final (type, field) in fields.take(200))
          _FieldRow(
            field: field,
            owner: type.name,
            showOwner: true,
            onOpen: _open,
            onUse: switch (_kindOf(type)) {
              final kind? => () => Navigator.of(
                context,
              ).pop((kind: kind, field: field.name)),
              null => null,
            },
          ),
      ],
    );
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({required this.type, required this.onOpen});

  final GraphQlType type;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: Key('schema-type-${type.name}'),
      onTap: () => onOpen(type.name),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          spacing: 10,
          children: [
            Flexible(
              child: Text(
                type.name,
                style: mono.copyWith(color: scheme.primary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              type.kind.toLowerCase().replaceAll('_', ' '),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// One field: its signature, what it is for, and where it leads.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.field,
    required this.owner,
    required this.onOpen,
    this.onUse,
    this.showOwner = false,
  });

  final GraphQlField field;

  /// The type the field belongs to.
  final String owner;
  final bool showOwner;
  final ValueChanged<String> onOpen;

  /// Writes a query for the field; null when it is not a root field.
  final VoidCallback? onUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final code = mono.copyWith(fontSize: 12.5);
    final muted = code.copyWith(color: scheme.onSurfaceVariant);
    final args = [
      for (final a in field.args)
        '${a.name}: ${a.typeName}'
            '${a.defaultValue.isEmpty ? '' : ' = ${a.defaultValue}'}',
    ].join(', ');
    return InkWell(
      key: Key('schema-field-$owner.${field.name}'),
      // An enum's values and plain values lead nowhere.
      onTap: field.namedType.isEmpty ? null : () => onOpen(field.namedType),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        if (showOwner) TextSpan(text: '$owner.', style: muted),
                        TextSpan(
                          text: field.name,
                          style: code.copyWith(
                            fontWeight: FontWeight.w600,
                            decoration: field.deprecated
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        if (args.isNotEmpty)
                          TextSpan(text: '($args)', style: muted),
                        if (field.typeName.isNotEmpty) ...[
                          TextSpan(text: ': ', style: muted),
                          TextSpan(
                            text: field.typeName,
                            style: code.copyWith(color: scheme.primary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (field.description.isNotEmpty || field.deprecated)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        [
                          if (field.deprecated) 'Deprecated.',
                          field.description,
                        ].join(' ').trim(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (onUse != null)
              TextButton(
                key: Key('schema-use-${field.name}'),
                onPressed: onUse,
                child: const Text('Use'),
              ),
          ],
        ),
      ),
    );
  }
}
