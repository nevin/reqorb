/// Reading an OpenAPI 3 or Swagger 2 document, in JSON or YAML, into what
/// the spec page shows: the API's details, its operations, and what is
/// wrong with it.
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:yaml/yaml.dart';

/// Something wrong with a document, and the line it is on when known.
typedef SpecProblem = ({String message, int? line});

/// A parameter of an operation, such as `id` in the path.
typedef SpecParameter = ({
  String name,
  String location,
  bool required,
  String type,
  String description,
});

/// What a request body or a response carries, for one content type:
/// the type, its schema in a few words, and the document's media type
/// object for it, in OpenAPI 3's shape, to make an example from.
typedef SpecContent = ({
  String type,
  String schema,
  Map<String, Object?> media,
});

/// One response an operation may give.
typedef SpecResponse = ({
  String status,
  String description,
  List<SpecContent> content,
});

/// One field of a schema. Fields of an object inside it follow it, one
/// [depth] further in.
typedef SpecField = ({
  String name,
  String type,
  bool required,
  String description,
  List<String> notes,
  int depth,
});

/// A named schema, from `components/schemas` or Swagger 2's `definitions`.
class SpecSchema {
  const SpecSchema({
    required this.name,
    required this.type,
    required this.description,
    required this.fields,
    required this.notes,
  });

  final String name;
  final String type;
  final String description;
  final List<SpecField> fields;

  /// What else it says: the values it allows, what it extends, and such.
  final List<String> notes;
}

/// A way of authenticating that the API declares.
typedef SpecSecurity = ({String name, String summary, String description});

/// One method on one path.
class SpecOperation {
  const SpecOperation({
    required this.method,
    required this.path,
    required this.summary,
    required this.description,
    required this.operationId,
    required this.tags,
    required this.deprecated,
    required this.parameters,
    required this.body,
    required this.responses,
    this.webhook = false,
  });

  final String method;

  /// The path; for a webhook, its name.
  final String path;

  /// Whether this is a request the API sends rather than one it takes:
  /// an OpenAPI 3.1 webhook.
  final bool webhook;
  final String summary;
  final String description;
  final String operationId;
  final List<String> tags;
  final bool deprecated;
  final List<SpecParameter> parameters;
  final List<SpecContent> body;
  final List<SpecResponse> responses;
}

/// A document read as an API description.
class ApiSpec {
  const ApiSpec({
    required this.format,
    required this.specVersion,
    required this.title,
    required this.version,
    required this.description,
    required this.servers,
    required this.operations,
    required this.problems,
    this.schemas = const [],
    this.security = const [],
    this.document = const {},
  });

  /// `json` or `yaml`: what the text was written in.
  final String format;

  /// Such as `OpenAPI 3.1.0` or `Swagger 2.0`; empty when it says neither.
  final String specVersion;
  final String title;
  final String version;
  final String description;
  final List<String> servers;
  final List<SpecOperation> operations;
  final List<SpecProblem> problems;
  final List<SpecSchema> schemas;
  final List<SpecSecurity> security;

  /// The document as plain maps and lists, for what is worked out only
  /// when it is wanted, such as examples.
  final Map<String, Object?> document;

  /// Whether the text could be read at all; when not, [problems] says why.
  bool get readable => format.isNotEmpty;

  /// The webhooks, which are kept apart from the paths.
  List<SpecOperation> get webhooks => [
    for (final op in operations)
      if (op.webhook) op,
  ];

  /// The operations on paths by their first tag, in the order the tags
  /// first appear; untagged ones last, under `Other`.
  Map<String, List<SpecOperation>> get byTag {
    final groups = <String, List<SpecOperation>>{};
    final paths = [
      for (final op in operations)
        if (!op.webhook) op,
    ];
    for (final op in paths) {
      if (op.tags.isNotEmpty) (groups[op.tags.first] ??= []).add(op);
    }
    final untagged = [
      for (final op in paths)
        if (op.tags.isEmpty) op,
    ];
    if (untagged.isNotEmpty) groups['Other'] = untagged;
    return groups;
  }
}

/// Whether [text] looks like JSON rather than YAML.
bool looksLikeJson(String text) {
  final start = text.trimLeft();
  return start.startsWith('{') || start.startsWith('[');
}

/// [text], JSON or YAML, as plain maps and lists. Throws when it cannot
/// be read.
Object? readTree(String text) =>
    looksLikeJson(text) ? jsonDecode(text) : _plain(loadYaml(text));

const _methods = [
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
];

/// Reads [text] as an OpenAPI or Swagger document. Never throws: what
/// cannot be read is reported in [ApiSpec.problems].
ApiSpec readSpec(String text) {
  final json = looksLikeJson(text);
  Object? root;
  YamlNode? tree;
  try {
    if (json) {
      root = jsonDecode(text);
    } else {
      final value = loadYaml(text);
      // Kept, as it knows the line each part of the document is on.
      if (value is YamlNode) tree = value;
      root = _plain(value);
    }
  } on YamlException catch (e) {
    return _unreadable(
      'Not valid YAML: ${e.message}',
      e.span == null ? null : e.span!.start.line + 1,
    );
  } on FormatException catch (e) {
    return _unreadable('Not valid JSON: ${e.message}', _jsonLine(text, e));
  } catch (e) {
    return _unreadable('Could not read the document: $e', null);
  }
  if (root is! Map<String, Object?>) {
    return _unreadable(
      text.trim().isEmpty
          ? 'The document is empty'
          : 'The document is not an object of named fields',
      null,
    );
  }
  return _Reader(root, text, json ? 'json' : 'yaml', tree).read();
}

/// How long a document can be, in characters, and still be read on the
/// UI isolate: about 30 ms. Longer ones would stall typing.
const readInBackgroundOver = 64 * 1024;

/// [readSpec], on another isolate when [text] is long enough to need it.
Future<ApiSpec> readSpecApart(String text) => text.length > readInBackgroundOver
    ? Isolate.run(() => readSpec(text), debugName: 'readSpec')
    : Future.value(readSpec(text));

ApiSpec _unreadable(String message, int? line) => ApiSpec(
  format: '',
  specVersion: '',
  title: '',
  version: '',
  description: '',
  servers: const [],
  operations: const [],
  problems: [(message: message, line: line)],
);

/// The line a JSON error is on, from its offset.
int? _jsonLine(String text, FormatException e) {
  final offset = e.offset;
  if (offset == null || offset > text.length) return null;
  return '\n'.allMatches(text.substring(0, offset)).length + 1;
}

/// YAML's maps and lists as plain Dart ones, keyed by strings.
Object? _plain(Object? node) => switch (node) {
  YamlMap() => {
    for (final entry in node.entries) '${entry.key}': _plain(entry.value),
  },
  YamlList() => [for (final item in node) _plain(item)],
  _ => node,
};

class _Reader {
  _Reader(this.root, this.text, this.format, this._tree);

  final Map<String, Object?> root;
  final String text;
  final String format;
  final problems = <SpecProblem>[];

  bool get _swagger => root['swagger'] != null;

  /// The document as YAML nodes, which know their lines. JSON is read
  /// this way too, but only once a problem needs a line: JSON is YAML,
  /// but YAML is slower to read.
  YamlNode? _tree;
  bool _treeTried = false;
  YamlNode? get _nodes {
    if (_tree == null && !_treeTried) {
      _treeTried = true;
      try {
        if (loadYamlNode(text) case final YamlMap map) _tree = map;
      } catch (_) {
        // Lines are a help, not a need.
      }
    }
    return _tree;
  }

  /// Notes a problem with the part of the document [at], a path of keys
  /// and indexes such as `['paths', '/pets', 'get']`, or with the first
  /// use of [ref].
  void _problem(String message, {List<Object>? at, String? ref}) {
    // A broken reference is met as often as it is used; once says it.
    if (problems.any((p) => p.message == message)) return;
    final line = at != null
        ? _lineAt(at)
        : ref != null
        ? _lineOfRef(ref)
        : null;
    problems.add((message: message, line: line));
  }

  /// The line [path] is on, or as far along it as the document goes.
  int? _lineAt(List<Object> path) {
    var node = _nodes;
    int? line;
    for (final step in path) {
      if (node is YamlMap) {
        final key = node.nodes.keys.whereType<YamlNode>().where(
          (key) => '${key.value}' == '$step',
        );
        if (key.isEmpty) break;
        line = key.first.span.start.line + 1;
        node = node.nodes[key.first];
      } else if (node is YamlList && step is int && step < node.length) {
        node = node.nodes[step];
        line = node.span.start.line + 1;
      } else {
        break;
      }
    }
    return line;
  }

  /// The line of the first `$ref` to [ref].
  int? _lineOfRef(String ref) {
    final match = RegExp(
      '${RegExp.escape(ref)}(?=["\'\\s,}]|\$)',
      multiLine: true,
    ).firstMatch(text);
    if (match == null) return null;
    return '\n'.allMatches(text.substring(0, match.start)).length + 1;
  }

  /// [node], or what it refers to when it is a local `$ref`.
  Map<String, Object?> _resolve(Object? node, [int depth = 0]) {
    if (node is! Map<String, Object?>) return const {};
    final ref = node[r'$ref'];
    if (ref is! String || depth > 20) return node;
    if (!ref.startsWith('#/')) return node;
    Object? at = root;
    for (final part in ref.substring(2).split('/')) {
      final key = part.replaceAll('~1', '/').replaceAll('~0', '~');
      at = at is Map<String, Object?> ? at[key] : null;
    }
    if (at == null) {
      _problem('Nothing at $ref', ref: ref);
      return const {};
    }
    return _resolve(at, depth + 1);
  }

  /// A schema in a few words: `Pet`, `array of Pet`, `string (uuid)`.
  String _schema(Object? node, [int depth = 0]) {
    if (node is! Map<String, Object?>) return '';
    if (node[r'$ref'] case final String ref) {
      _resolve(node);
      return ref.split('/').last;
    }
    if (depth > 3) return '…';
    for (final combiner in const ['oneOf', 'anyOf', 'allOf']) {
      if (node[combiner] case final List<Object?> options) {
        final names = [for (final o in options) _schema(o, depth + 1)];
        return '$combiner(${names.join(', ')})';
      }
    }
    final type = switch (node['type']) {
      final List<Object?> types => types.join(' | '),
      final Object type => '$type',
      null => node['properties'] != null ? 'object' : '',
    };
    if (type == 'array') {
      final items = _schema(node['items'], depth + 1);
      return items.isEmpty ? 'array' : 'array of $items';
    }
    if ((type == 'object' || type.isEmpty) && node['properties'] == null) {
      if (node['additionalProperties'] case final Map<String, Object?> values) {
        final of = _schema(values, depth + 1);
        return of.isEmpty ? 'map' : 'map of $of';
      }
    }
    final format = node['format'];
    return format == null ? type : '$type ($format)';
  }

  String _string(Object? value) => value is String ? value : '';

  ApiSpec read() {
    final openapi = root['openapi'];
    final swagger = root['swagger'];
    final specVersion = openapi != null
        ? 'OpenAPI $openapi'
        : swagger != null
        ? 'Swagger $swagger'
        : '';
    if (specVersion.isEmpty) {
      _problem('Says neither "openapi" nor "swagger": which version is it?');
    }
    final info = root['info'] is Map<String, Object?>
        ? root['info'] as Map<String, Object?>
        : const <String, Object?>{};
    if (root['info'] == null) _problem('Has no "info"');
    if (info.isNotEmpty && _string(info['title']).isEmpty) {
      _problem('The info has no title', at: ['info', 'title']);
    }
    if (info.isNotEmpty && info['version'] == null) {
      _problem('The info has no version', at: ['info']);
    }
    final paths = root['paths'];
    final webhooks = root['webhooks'];
    final hasPaths = paths is Map<String, Object?> && paths.isNotEmpty;
    final hasWebhooks = webhooks is Map<String, Object?> && webhooks.isNotEmpty;
    // OpenAPI 3.1 asks for any one of these; earlier versions for paths,
    // though there may be none in it.
    if ('$openapi'.startsWith('3.1')) {
      if (!hasPaths && !hasWebhooks && root['components'] == null) {
        _problem('Has no paths, webhooks or components');
      }
    } else if (paths is! Map<String, Object?>) {
      _problem('Has no paths, so no operations');
    }
    final ids = <String>{};
    final operations = [
      if (hasPaths) ..._operations(paths, ids),
      if (hasWebhooks) ..._operations(webhooks, ids, webhooks: true),
    ];
    return ApiSpec(
      format: format,
      specVersion: specVersion,
      title: _string(info['title']),
      version: info['version'] == null ? '' : '${info['version']}',
      description: _string(info['description']),
      servers: _servers(),
      operations: operations,
      problems: problems,
      schemas: _schemas(),
      security: _security(),
      document: root,
    );
  }

  Map<String, Object?> _map(Object? node) =>
      node is Map<String, Object?> ? node : const {};

  List<SpecSchema> _schemas() {
    final named = _swagger
        ? _map(root['definitions'])
        : _map(_map(root['components'])['schemas']);
    return [
      for (final MapEntry(key: name, :value) in named.entries)
        if (value is Map<String, Object?>) _named(name, value),
    ];
  }

  SpecSchema _named(String name, Map<String, Object?> node) {
    final parents = [
      if (node['allOf'] case final List<Object?> parts)
        for (final part in parts)
          if (_map(part)[r'$ref'] case final String ref) ref.split('/').last,
    ];
    final fields = _fields(node, 0, {name});
    return SpecSchema(
      name: name,
      // An object put together from others is still an object.
      type: node['allOf'] != null && node['oneOf'] == null
          ? 'object'
          : _schema(node).isEmpty && fields.isNotEmpty
          ? 'object'
          : _schema(node),
      description: _string(node['description']),
      fields: fields,
      notes: [
        if (parents.isNotEmpty) 'extends ${parents.join(', ')}',
        ..._notes(node),
      ],
    );
  }

  /// The fields of [node], with those of what it extends, and those of
  /// any object written out inside it, one level further in. A field
  /// that refers to another schema is not opened: that schema is shown
  /// on its own.
  List<SpecField> _fields(
    Map<String, Object?> node,
    int depth,
    Set<String> seen,
  ) {
    final out = <SpecField>[];
    final required = <String>{
      if (node['required'] case final List<Object?> names)
        for (final name in names) '$name',
    };
    if (node['allOf'] case final List<Object?> parts) {
      for (final part in parts) {
        final map = _map(part);
        if (map[r'$ref'] case final String ref) {
          final name = ref.split('/').last;
          if (seen.add(name)) out.addAll(_fields(_resolve(map), depth, seen));
        } else {
          out.addAll(_fields(map, depth, seen));
        }
      }
    }
    for (final MapEntry(key: name, :value) in _map(
      node['properties'],
    ).entries) {
      final field = _map(value);
      out.add((
        name: name,
        type: _schema(field),
        required: required.contains(name),
        description: _string(field['description']),
        notes: _notes(field),
        depth: depth,
      ));
      if (field[r'$ref'] != null || depth >= 4) continue;
      final items = _map(field['items']);
      final inner = field['properties'] != null || field['allOf'] != null
          ? field
          : items[r'$ref'] == null && items['properties'] != null
          ? items
          : null;
      if (inner != null) out.addAll(_fields(inner, depth + 1, seen));
    }
    return out;
  }

  /// What a schema says beyond its type, in short.
  List<String> _notes(Map<String, Object?> node) {
    String shown(Object? value) {
      final text = value is String ? value : jsonEncode(value);
      return text.length > 60 ? '${text.substring(0, 57)}…' : text;
    }

    return [
      if (node['enum'] case final List<Object?> values)
        'one of: ${values.take(12).map(shown).join(', ')}'
            '${values.length > 12 ? ', …' : ''}',
      if (node.containsKey('const')) 'always ${shown(node['const'])}',
      if (node.containsKey('default')) 'default ${shown(node['default'])}',
      if (node.containsKey('example')) 'example ${shown(node['example'])}',
      for (final (key, label) in const [
        ('minLength', 'min length'),
        ('maxLength', 'max length'),
        ('minimum', 'min'),
        ('maximum', 'max'),
        ('minItems', 'min items'),
        ('maxItems', 'max items'),
        ('pattern', 'pattern'),
      ])
        if (node[key] != null) '$label ${node[key]}',
      if (node['nullable'] == true) 'nullable',
      if (node['readOnly'] == true) 'read-only',
      if (node['writeOnly'] == true) 'write-only',
      if (node['deprecated'] == true) 'deprecated',
    ];
  }

  List<SpecSecurity> _security() {
    final schemes = _swagger
        ? _map(root['securityDefinitions'])
        : _map(_map(root['components'])['securitySchemes']);
    return [
      for (final MapEntry(key: name, :value) in schemes.entries)
        () {
          final scheme = _resolve(value);
          final type = _string(scheme['type']);
          final summary = switch (type) {
            'apiKey' =>
              'API key in the ${_string(scheme['in'])} '
                  '"${_string(scheme['name'])}"',
            'http' => [
              'HTTP ${_string(scheme['scheme'])}',
              if (_string(scheme['bearerFormat']) case final f
                  when f.isNotEmpty)
                '($f)',
            ].join(' '),
            'basic' => 'HTTP basic',
            'oauth2' => [
              'OAuth 2',
              if (scheme['flows'] case final Map<String, Object?> flows)
                '(${flows.keys.join(', ')})'
              else if (_string(scheme['flow']) case final f when f.isNotEmpty)
                '($f)',
            ].join(' '),
            'openIdConnect' => 'OpenID Connect',
            'mutualTLS' => 'Mutual TLS',
            _ => type,
          };
          return (
            name: name,
            summary: summary,
            description: _string(scheme['description']),
          );
        }(),
    ];
  }

  List<String> _servers() {
    if (_swagger) {
      final host = _string(root['host']);
      if (host.isEmpty) return const [];
      final schemes = root['schemes'] is List<Object?>
          ? [for (final s in root['schemes'] as List<Object?>) '$s']
          : ['https'];
      final base = _string(root['basePath']);
      return [for (final scheme in schemes) '$scheme://$host$base'];
    }
    return [
      if (root['servers'] case final List<Object?> servers)
        for (final (i, server) in servers.indexed)
          if (server is Map<String, Object?> && server['url'] is String)
            _serverUrl(server, ['servers', i]),
    ];
  }

  /// A server's URL with each `{variable}` in it set to its default.
  /// [at] is where the server is in the document.
  String _serverUrl(Map<String, Object?> server, List<Object> at) {
    final url = server['url'] as String;
    final variables = server['variables'] is Map<String, Object?>
        ? server['variables'] as Map<String, Object?>
        : const <String, Object?>{};
    return url.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
      final name = match[1]!;
      final variable = variables[name];
      final fallback = variable is Map<String, Object?>
          ? variable['default']
          : null;
      if (fallback == null) {
        _problem(
          variable == null
              ? 'The server $url does not define its variable "$name"'
              : 'The server variable "$name" has no default',
          at: [...at, 'variables', name],
        );
        return match[0]!;
      }
      return '$fallback';
    });
  }

  /// The operations of each path item in [items]: the paths, or with
  /// [webhooks] the webhooks, which are named rather than paths.
  List<SpecOperation> _operations(
    Map<String, Object?> items,
    Set<String> ids, {
    bool webhooks = false,
  }) {
    final operations = <SpecOperation>[];
    for (final MapEntry(key: path, value: node) in items.entries) {
      final item = _resolve(node);
      final shared = _parameters(item['parameters']);
      for (final method in _methods) {
        final op = item[method];
        if (op is! Map<String, Object?>) continue;
        final where = webhooks
            ? 'The webhook $path (${method.toUpperCase()})'
            : '${method.toUpperCase()} $path';
        final at = [webhooks ? 'webhooks' : 'paths', path, method];
        final parameters = _merge(shared, _parameters(op['parameters']));
        final id = _string(op['operationId']);
        if (id.isNotEmpty && !ids.add(id)) {
          _problem(
            '$where repeats the operationId "$id"',
            at: [...at, 'operationId'],
          );
        }
        for (final name
            in webhooks
                ? const <RegExpMatch>[]
                : RegExp(r'\{([^}]+)\}').allMatches(path)) {
          final declared = parameters.any(
            (p) => p.location == 'path' && p.name == name[1],
          );
          if (!declared) {
            _problem(
              '$where does not declare its path parameter '
              '"${name[1]}"',
              at: at,
            );
          }
        }
        final responses = _responses(op);
        if (responses.isEmpty) {
          _problem('$where lists no responses', at: [...at, 'responses']);
        }
        operations.add(
          SpecOperation(
            method: method.toUpperCase(),
            path: path,
            summary: _string(op['summary']),
            description: _string(op['description']),
            operationId: id,
            tags: [
              if (op['tags'] case final List<Object?> tags)
                for (final tag in tags) '$tag',
            ],
            deprecated: op['deprecated'] == true,
            parameters: [
              for (final p in parameters)
                if (p.location != 'body' && p.location != 'formData') p,
            ],
            body: _body(op, parameters),
            responses: responses,
            webhook: webhooks,
          ),
        );
      }
    }
    return operations;
  }

  /// [own] over [shared]: an operation's parameter replaces the path's
  /// one of the same name and place.
  List<SpecParameter> _merge(
    List<SpecParameter> shared,
    List<SpecParameter> own,
  ) => [
    for (final p in shared)
      if (!own.any((o) => o.name == p.name && o.location == p.location)) p,
    ...own,
  ];

  /// Swagger 2 keeps a body's schema on its `body` parameter: in a few
  /// words, and as written.
  final _bodySchemas = <String, String>{};
  final _bodyNodes = <String, Object?>{};

  List<SpecParameter> _parameters(Object? list) {
    if (list is! List<Object?>) return const [];
    final out = <SpecParameter>[];
    for (final node in list) {
      final p = _resolve(node);
      final name = _string(p['name']);
      final location = _string(p['in']);
      if (location == 'body') {
        _bodySchemas[name] = _schema(p['schema']);
        _bodyNodes[name] = p['schema'];
      }
      out.add((
        name: name,
        location: location,
        required: p['required'] == true,
        // Swagger 2 puts the type on the parameter, OpenAPI 3 in a schema.
        type: p['schema'] != null ? _schema(p['schema']) : _schema(p),
        description: _string(p['description']),
      ));
    }
    return out;
  }

  List<SpecContent> _content(Object? node) {
    if (node is! Map<String, Object?>) return const [];
    return [
      for (final MapEntry(key: type, :value) in node.entries)
        (
          type: type,
          schema: _schema(_resolve(value)['schema']),
          media: _resolve(value),
        ),
    ];
  }

  List<SpecContent> _body(
    Map<String, Object?> op,
    List<SpecParameter> parameters,
  ) {
    if (op['requestBody'] != null) {
      return _content(_resolve(op['requestBody'])['content']);
    }
    // Swagger 2: a body parameter, or form fields.
    final consumes = op['consumes'] ?? root['consumes'];
    final types = consumes is List<Object?>
        ? [for (final t in consumes) '$t']
        : ['application/json'];
    for (final p in parameters) {
      if (p.location == 'body') {
        final schema = _bodySchemas[p.name] ?? '';
        return [
          for (final type in types)
            (type: type, schema: schema, media: {'schema': _bodyNodes[p.name]}),
        ];
      }
    }
    final fields = [
      for (final p in parameters)
        if (p.location == 'formData') p.name,
    ];
    if (fields.isEmpty) return const [];
    return [
      (
        type: types.firstWhere(
          (t) => t.contains('form'),
          orElse: () => 'application/x-www-form-urlencoded',
        ),
        schema: 'fields: ${fields.join(', ')}',
        media: const {},
      ),
    ];
  }

  List<SpecResponse> _responses(Map<String, Object?> op) {
    final responses = op['responses'];
    if (responses is! Map<String, Object?>) return const [];
    final produces = op['produces'] ?? root['produces'];
    return [
      for (final MapEntry(key: status, :value) in responses.entries)
        () {
          final response = _resolve(value);
          final List<SpecContent> content;
          if (_swagger) {
            final schema = _schema(response['schema']);
            final examples = _map(response['examples']);
            content = schema.isEmpty
                ? const []
                : [
                    for (final type
                        in produces is List<Object?>
                            ? [for (final t in produces) '$t']
                            : ['application/json'])
                      (
                        type: type,
                        schema: schema,
                        media: {
                          'schema': response['schema'],
                          if (examples.containsKey(type))
                            'example': examples[type],
                        },
                      ),
                  ];
          } else {
            content = _content(response['content']);
          }
          return (
            status: status,
            description: _string(response['description']),
            content: content,
          );
        }(),
    ];
  }
}

/// An example of what [content] carries, as indented JSON: the one the
/// document gives, or else one made up from its schema. Fields only the
/// server writes are left out of a [request], and those only the client
/// writes out of a response. Null for content that is not JSON, or
/// whose schema says too little to make one from.
String? exampleOf(ApiSpec spec, SpecContent content, {required bool request}) {
  final type = content.type.toLowerCase();
  if (!type.contains('json') && type != '*/*') return null;
  final examples = _Examples(spec.document, request: request);
  final media = content.media;
  Object? value;
  if (media.containsKey('example')) {
    value = media['example'];
  } else if (media['examples'] case final Map<String, Object?> named
      when named.isNotEmpty) {
    value = examples.follow(named.values.first)['value'];
  } else {
    value = examples.of(media['schema']);
  }
  return value == null
      ? null
      : const JsonEncoder.withIndent('  ').convert(value);
}

/// Makes up values that schemas allow.
class _Examples {
  _Examples(this.root, {required this.request});

  final Map<String, Object?> root;
  final bool request;

  /// How far into nested objects an example goes.
  static const _deepest = 8;

  /// [node], or what it refers to when it is a local `$ref`.
  Map<String, Object?> follow(Object? node, [int depth = 0]) {
    if (node is! Map<String, Object?>) return const {};
    final ref = node[r'$ref'];
    if (ref is! String || !ref.startsWith('#/') || depth > 20) return node;
    Object? at = root;
    for (final part in ref.substring(2).split('/')) {
      final key = part.replaceAll('~1', '/').replaceAll('~0', '~');
      at = at is Map<String, Object?> ? at[key] : null;
    }
    return follow(at, depth + 1);
  }

  /// A value [node] allows, or null for none. [within] holds the schemas
  /// this one is inside, so that one that contains itself stops.
  Object? of(Object? node, [Set<String> within = const {}, int depth = 0]) {
    if (node is! Map<String, Object?> || depth > _deepest) return null;
    if (node[r'$ref'] case final String ref) {
      if (within.contains(ref)) return null;
      return of(follow(node), {...within, ref}, depth);
    }
    if (node.containsKey('example')) return node['example'];
    // OpenAPI 3.1 schemas list their examples.
    if (node['examples'] case final List<Object?> listed
        when listed.isNotEmpty) {
      return listed.first;
    }
    if (node.containsKey('const')) return node['const'];
    if (node.containsKey('default')) return node['default'];
    if (node['enum'] case final List<Object?> values when values.isNotEmpty) {
      return values.first;
    }
    for (final choice in const ['oneOf', 'anyOf']) {
      if (node[choice] case final List<Object?> options
          when options.isNotEmpty) {
        return of(options.first, within, depth);
      }
    }
    if (node['allOf'] case final List<Object?> parts) {
      final merged = <String, Object?>{};
      for (final part in parts) {
        if (of(part, within, depth) case final Map<String, Object?> value) {
          merged.addAll(value);
        }
      }
      if (_object(node, within, depth) case final Map<String, Object?> own) {
        merged.addAll(own);
      }
      return merged;
    }
    final type = switch (node['type']) {
      // OpenAPI 3.1 writes a nullable type as a list with `null` in it.
      final List<Object?> types => types.firstWhere(
        (t) => t != 'null',
        orElse: () => null,
      ),
      final Object type => type,
      null =>
        node['properties'] != null
            ? 'object'
            : node['items'] != null
            ? 'array'
            : null,
    };
    return switch (type) {
      'object' => _object(node, within, depth) ?? <String, Object?>{},
      'array' => [?of(node['items'], within, depth + 1)],
      'string' => _string(node),
      'integer' => node['minimum'] ?? 0,
      'number' => node['minimum'] ?? 0.0,
      'boolean' => true,
      _ => null,
    };
  }

  /// The fields of an object [node], each with a value.
  Map<String, Object?>? _object(
    Map<String, Object?> node,
    Set<String> within,
    int depth,
  ) {
    final properties = node['properties'];
    final more = node['additionalProperties'];
    if (properties is! Map<String, Object?>) {
      if (more is! Map<String, Object?>) return null;
      return {'key': of(more, within, depth + 1)};
    }
    return {
      for (final MapEntry(key: name, :value) in properties.entries)
        // A field with nothing to show, such as one that would repeat
        // a schema it is inside, is left out rather than sent as null.
        if (_belongs(follow(value))) name: ?of(value, within, depth + 1),
    };
  }

  /// Whether a field goes in this direction.
  bool _belongs(Map<String, Object?> field) =>
      !(request ? field['readOnly'] == true : field['writeOnly'] == true);

  String _string(Map<String, Object?> node) => switch (node['format']) {
    'date-time' => '2024-01-01T00:00:00Z',
    'date' => '2024-01-01',
    'time' => '00:00:00',
    'email' => 'user@example.com',
    'uuid' => '3fa85f64-5717-4562-b3fc-2c963f66afa6',
    'uri' || 'url' => 'https://example.com',
    'hostname' => 'example.com',
    'ipv4' => '192.0.2.1',
    'ipv6' => '2001:db8::1',
    'byte' => 'c3RyaW5n',
    'password' => '********',
    _ => 'string',
  };
}

/// A small OpenAPI 3 document to start a new one from.
const specTemplate = '''openapi: 3.0.3
info:
  title: My API
  version: 1.0.0
  description: What this API is for.
servers:
  - url: https://api.example.com/v1
paths:
  /items:
    get:
      tags: [items]
      summary: List the items
      parameters:
        - name: limit
          in: query
          schema:
            type: integer
      responses:
        "200":
          description: The items
          content:
            application/json:
              schema:
                type: array
                items:
                  \$ref: "#/components/schemas/Item"
    post:
      tags: [items]
      summary: Add an item
      requestBody:
        content:
          application/json:
            schema:
              \$ref: "#/components/schemas/Item"
      responses:
        "201":
          description: The item, as added
  /items/{id}:
    get:
      tags: [items]
      summary: Get one item
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        "200":
          description: The item
        "404":
          description: No such item
components:
  schemas:
    Item:
      type: object
      properties:
        id:
          type: string
        name:
          type: string
''';
