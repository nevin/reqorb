import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/spec/api_spec.dart';
import 'package:reqorb/spec/spec_page.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  group('reading a spec', () {
    test('an OpenAPI 3 document in YAML', () {
      final spec = readSpec(specTemplate);
      expect(spec.problems, isEmpty);
      expect(spec.format, 'yaml');
      expect(spec.specVersion, 'OpenAPI 3.0.3');
      expect(spec.title, 'My API');
      expect(spec.version, '1.0.0');
      expect(spec.servers, ['https://api.example.com/v1']);
      expect(spec.operations.map((o) => '${o.method} ${o.path}'), [
        'GET /items',
        'POST /items',
        'GET /items/{id}',
      ]);
      expect(spec.byTag.keys, ['items']);
      final list = spec.operations.first;
      expect(list.parameters.single.name, 'limit');
      expect(list.parameters.single.type, 'integer');
      expect(list.responses.single.content.single.schema, 'array of Item');
      expect(spec.operations[1].body.single, (
        type: 'application/json',
        schema: 'Item',
      ));
    });

    test('a Swagger 2 document in JSON', () {
      final spec = readSpec('''
{
  "swagger": "2.0",
  "info": {"title": "Pets", "version": "1"},
  "host": "pets.test", "basePath": "/v2", "schemes": ["https"],
  "paths": {
    "/pets": {
      "post": {
        "parameters": [
          {"name": "pet", "in": "body", "schema": {"\$ref": "#/definitions/Pet"}}
        ],
        "responses": {"200": {"description": "ok", "schema": {"type": "array", "items": {"\$ref": "#/definitions/Pet"}}}}
      }
    }
  },
  "definitions": {"Pet": {"type": "object"}}
}''');
      expect(spec.problems, isEmpty);
      expect(spec.format, 'json');
      expect(spec.specVersion, 'Swagger 2.0');
      expect(spec.servers, ['https://pets.test/v2']);
      final op = spec.operations.single;
      expect(op.parameters, isEmpty);
      expect(op.body.single.schema, 'Pet');
      expect(op.responses.single.content.single.schema, 'array of Pet');
      expect(spec.byTag.keys, ['Other']);
    });

    test('says what is wrong, and where', () {
      final spec = readSpec('''
openapi: 3.0.0
info:
  version: 1
paths:
  /pets/{id}:
    get:
      operationId: getPet
      responses:
        "200":
          \$ref: "#/components/responses/Missing"
    put:
      operationId: getPet
''');
      final messages = spec.problems.map((p) => p.message).toList();
      expect(messages, contains('The info has no title'));
      expect(messages, contains('Nothing at #/components/responses/Missing'));
      expect(
        messages,
        contains('GET /pets/{id} does not declare its path parameter "id"'),
      );
      expect(
        messages,
        contains('PUT /pets/{id} repeats the operationId "getPet"'),
      );
      expect(messages, contains('PUT /pets/{id} lists no responses'));
    });

    test('OpenAPI 3.1: webhooks, and no paths needed', () {
      final spec = readSpec('''
openapi: 3.1.0
info: {title: Events, version: "1"}
servers:
  - url: https://{env}.events.test:{port}/v1
    variables:
      env: {default: api, enum: [api, staging]}
      port: {default: "443"}
webhooks:
  newPet:
    post:
      summary: A pet was added
      requestBody:
        content:
          application/json:
            schema: {type: [object, "null"]}
      responses:
        "200": {description: Received}
''');
      expect(spec.problems, isEmpty);
      expect(spec.servers, ['https://api.events.test:443/v1']);
      expect(spec.byTag, isEmpty);
      final hook = spec.webhooks.single;
      expect(hook.path, 'newPet');
      expect(hook.method, 'POST');
      expect(hook.body.single.schema, 'object | null');
    });

    test('3.1 still needs something, and 3.0 still needs paths', () {
      expect(
        readSpec('openapi: 3.1.0\ninfo: {title: A, version: "1"}\n')
            .problems
            .single
            .message,
        'Has no paths, webhooks or components',
      );
      expect(
        readSpec(
          'openapi: 3.1.0\ninfo: {title: A, version: "1"}\ncomponents: {}\n',
        ).problems,
        isEmpty,
      );
      expect(
        readSpec(
          'openapi: 3.0.3\ninfo: {title: A, version: "1"}\nwebhooks: {}\n',
        ).problems.single.message,
        'Has no paths, so no operations',
      );
    });

    test('a server variable needs a default', () {
      final spec = readSpec('''
openapi: 3.0.3
info: {title: A, version: "1"}
servers:
  - url: https://{region}.a.test/{stage}
    variables:
      region: {enum: [eu, us]}
paths: {}
''');
      expect(spec.servers, ['https://{region}.a.test/{stage}']);
      final messages = spec.problems.map((p) => p.message);
      expect(messages, contains('The server variable "region" has no default'));
      expect(
        messages,
        contains(
          'The server https://{region}.a.test/{stage} does not define its '
          'variable "stage"',
        ),
      );
    });

    test('a document that cannot be read says on which line', () {
      final spec = readSpec('openapi: 3.0.0\ninfo:\n  title: [unclosed\n');
      expect(spec.readable, isFalse);
      expect(spec.problems.single.message, startsWith('Not valid YAML'));
      expect(spec.problems.single.line, isNotNull);
      expect(
        readSpec('{"openapi": ').problems.single.message,
        startsWith('Not valid JSON'),
      );
      expect(readSpec('').problems.single.message, 'The document is empty');
    });
  });

  test('YAML is coloured: keys, strings, literals and comments', () {
    const text =
        'title: "Pets"  # a comment\ndeprecated: true\n'
        'url: http://a.test/#frag\n';
    final tokens = {
      for (final t in tokenize(text, CodeLanguage.yaml))
        text.substring(t.start, t.end): t.kind,
    };
    expect(tokens['title'], TokenKind.key);
    expect(tokens['"Pets"'], TokenKind.string);
    expect(tokens['# a comment'], TokenKind.comment);
    expect(tokens['true'], TokenKind.keyword);
    // A # inside a value does not start a comment.
    expect(tokens.keys.where((k) => k.contains('frag')), isEmpty);
  });

  test('YAML: an apostrophe or a block of text is not code', () {
    const text =
        "info:\n  description: |-\n    It's here.\n"
        '    Some links: below\n  title: Pets\nnote: we\'ve one\n';
    final tokens = [
      for (final t in tokenize(text, CodeLanguage.yaml))
        (text.substring(t.start, t.end), t.kind),
    ];
    expect(tokens, [
      ('info', TokenKind.key),
      ('description', TokenKind.key),
      ('title', TokenKind.key),
      ('note', TokenKind.key),
    ]);
  });

  group('the main menu', () {
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = WorkspaceStore('unused.json', engine: FakeEngine());
      await tester.pumpWidget(ReqorbApp(store: store));
      await tester.pumpAndSettle();
    }

    testWidgets('has API specs and the HAR analyser', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('api-specs')), findsOneWidget);
      expect(find.byKey(const Key('har-analyser')), findsOneWidget);
      // Moved out of the header and the import menu.
      expect(find.byKey(const Key('analyze-har-button')), findsNothing);
      await tester.tap(find.byKey(const Key('import-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Analyse HAR file…'), findsNothing);
    });

    testWidgets('API specs opens, previews and edits a spec', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('api-specs')));
      await tester.pumpAndSettle();
      expect(find.text('Read and edit an API spec'), findsOneWidget);

      await tester.tap(find.byKey(const Key('spec-start-template')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spec-api-title')), findsOneWidget);
      expect(find.text('My API'), findsOneWidget);
      expect(find.text('No problems'), findsOneWidget);
      expect(find.byKey(const Key('spec-op-GET-/items/{id}')), findsOneWidget);

      // An edit is read again, and the title shows it is unsaved.
      final editor = find.byKey(const Key('spec-editor'));
      final text = tester.widget<TextField>(editor).controller!.text;
      await tester.enterText(editor, text.replaceFirst('My API', 'Shop'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Shop'), findsOneWidget);
      expect(find.text('• openapi.yaml'), findsOneWidget);

      await tester.tap(find.byKey(const Key('spec-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Convert to JSON'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<TextField>(editor).controller!.text,
        startsWith('{\n  "openapi": "3.0.3"'),
      );
    });

    testWidgets('webhooks have a section of their own', (tester) async {
      final original = specFetcher;
      specFetcher = (url) async =>
          '{"openapi": "3.1.0", "info": {"title": "Hooks", "version": "1"}, '
          '"webhooks": {"newPet": {"post": {"responses": '
          '{"200": {"description": "ok"}}}}}}';
      addTearDown(() => specFetcher = original);
      await open(tester);
      await tester.tap(find.byKey(const Key('api-specs')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('spec-start-url')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('spec-url-field')),
        'hooks.test/openapi.json',
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spec-webhooks')), findsOneWidget);
      expect(find.byKey(const Key('spec-op-POST-newPet')), findsOneWidget);
      expect(find.text('OpenAPI 3.1.0 · JSON · 1 webhook'), findsOneWidget);
      expect(find.text('No problems'), findsOneWidget);
    });

    testWidgets('a spec opens from a URL', (tester) async {
      final original = specFetcher;
      final fetched = <Uri>[];
      specFetcher = (url) async {
        fetched.add(url);
        return '{"openapi": "3.1.0", "info": {"title": "Remote", '
            '"version": "2"}, "paths": {}}';
      };
      addTearDown(() => specFetcher = original);
      await open(tester);
      await tester.tap(find.byKey(const Key('api-specs')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('spec-start-url')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('spec-url-field')),
        'api.test/openapi.json',
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(fetched, [Uri.parse('https://api.test/openapi.json')]);
      expect(find.text('Remote'), findsOneWidget);
      expect(find.text('openapi.json'), findsOneWidget);
    });
  });
}
