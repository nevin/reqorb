/// Reading an OpenAPI 3 or Swagger 2 document, in JSON or YAML, into what
/// the spec page shows: the API's details, its operations, and what is
/// wrong with it.
library;

import 'dart:convert';

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

/// What a request body or a response carries, for one content type.
typedef SpecContent = ({String type, String schema});

/// One response an operation may give.
typedef SpecResponse = ({
  String status,
  String description,
  List<SpecContent> content,
});

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
  });

  final String method;
  final String path;
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

  /// Whether the text could be read at all; when not, [problems] says why.
  bool get readable => format.isNotEmpty;

  /// The operations by their first tag, in the order the tags first
  /// appear; untagged ones last, under `Other`.
  Map<String, List<SpecOperation>> get byTag {
    final groups = <String, List<SpecOperation>>{};
    for (final op in operations) {
      if (op.tags.isNotEmpty) (groups[op.tags.first] ??= []).add(op);
    }
    final untagged = [
      for (final op in operations)
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

const _methods = ['get', 'put', 'post', 'delete', 'options', 'head', 'patch'];

/// Reads [text] as an OpenAPI or Swagger document. Never throws: what
/// cannot be read is reported in [ApiSpec.problems].
ApiSpec readSpec(String text) {
  final json = looksLikeJson(text);
  Object? root;
  try {
    root = readTree(text);
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
  return _Reader(root, text, json ? 'json' : 'yaml').read();
}

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
  _Reader(this.root, this.text, this.format);

  final Map<String, Object?> root;
  final String text;
  final String format;
  final problems = <SpecProblem>[];

  bool get _swagger => root['swagger'] != null;

  void _problem(String message, [String? near]) {
    problems.add((message: message, line: near == null ? null : _lineOf(near)));
  }

  /// The first line that mentions [key] as a key, to point a problem at.
  int? _lineOf(String key) {
    final quoted = RegExp(
      '^\\s*["\']?${RegExp.escape(key)}["\']?\\s*:',
      multiLine: true,
    );
    final match = quoted.firstMatch(text);
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
      _problem('Nothing at $ref', ref.split('/').last);
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
      _problem('The info has no title', 'info');
    }
    if (info.isNotEmpty && info['version'] == null) {
      _problem('The info has no version', 'info');
    }
    final operations = _operations();
    return ApiSpec(
      format: format,
      specVersion: specVersion,
      title: _string(info['title']),
      version: info['version'] == null ? '' : '${info['version']}',
      description: _string(info['description']),
      servers: _servers(),
      operations: operations,
      problems: problems,
    );
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
        for (final server in servers)
          if (server is Map<String, Object?> && server['url'] is String)
            server['url'] as String,
    ];
  }

  List<SpecOperation> _operations() {
    final paths = root['paths'];
    if (paths is! Map<String, Object?> || paths.isEmpty) {
      _problem('Has no paths, so no operations');
      return const [];
    }
    final operations = <SpecOperation>[];
    final ids = <String>{};
    for (final MapEntry(key: path, value: node) in paths.entries) {
      final item = _resolve(node);
      final shared = _parameters(item['parameters']);
      for (final method in _methods) {
        final op = item[method];
        if (op is! Map<String, Object?>) continue;
        final where = '${method.toUpperCase()} $path';
        final parameters = _merge(shared, _parameters(op['parameters']));
        final id = _string(op['operationId']);
        if (id.isNotEmpty && !ids.add(id)) {
          _problem('$where repeats the operationId "$id"', id);
        }
        for (final name in RegExp(r'\{([^}]+)\}').allMatches(path)) {
          final declared = parameters.any(
            (p) => p.location == 'path' && p.name == name[1],
          );
          if (!declared) {
            _problem(
              '$where does not declare its path parameter '
              '"${name[1]}"',
              path,
            );
          }
        }
        final responses = _responses(op);
        if (responses.isEmpty) _problem('$where lists no responses', path);
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

  /// Swagger 2 keeps a body's schema on its `body` parameter.
  final _bodySchemas = <String, String>{};

  List<SpecParameter> _parameters(Object? list) {
    if (list is! List<Object?>) return const [];
    final out = <SpecParameter>[];
    for (final node in list) {
      final p = _resolve(node);
      final name = _string(p['name']);
      final location = _string(p['in']);
      if (location == 'body') _bodySchemas[name] = _schema(p['schema']);
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
        (type: type, schema: _schema(_resolve(value)['schema'])),
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
        return [for (final type in types) (type: type, schema: schema)];
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
            content = schema.isEmpty
                ? const []
                : [
                    for (final type
                        in produces is List<Object?>
                            ? [for (final t in produces) '$t']
                            : ['application/json'])
                      (type: type, schema: schema),
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
