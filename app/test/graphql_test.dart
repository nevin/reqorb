import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/graphql/graphql_editor.dart';
import 'package:reqorb/graphql/graphql_session.dart';
import 'package:reqorb/graphql/schema_browser.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/request/request_draft.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

GraphQlField _field(
  String name,
  String type, {
  List<GraphQlArg> args = const [],
  String description = '',
  bool deprecated = false,
}) => GraphQlField(
  name: name,
  description: description,
  typeName: type,
  namedType: type.replaceAll(RegExp(r'[\[\]!]'), ''),
  args: args,
  deprecated: deprecated,
);

GraphQlType _type(
  String name,
  String kind, {
  List<GraphQlField> fields = const [],
  List<String> members = const [],
  String description = '',
}) => GraphQlType(
  name: name,
  kind: kind,
  description: description,
  fields: fields,
  members: members,
);

final _schema = GraphQlSchema(
  queryType: 'Query',
  mutationType: 'Mutation',
  subscriptionType: '',
  types: [
    _type('ID', 'SCALAR'),
    _type(
      'Mutation',
      'OBJECT',
      fields: [
        _field(
          'addUser',
          'User',
          args: const [
            GraphQlArg(
              name: 'role',
              description: '',
              typeName: 'Role',
              defaultValue: 'MEMBER',
            ),
          ],
        ),
      ],
    ),
    _type(
      'Query',
      'OBJECT',
      fields: [
        _field(
          'user',
          'User',
          description: 'One user.',
          args: const [
            GraphQlArg(
              name: 'id',
              description: '',
              typeName: 'ID!',
              defaultValue: '',
            ),
          ],
        ),
        _field('version', 'String'),
      ],
    ),
    _type(
      'Role',
      'ENUM',
      fields: const [
        GraphQlField(
          name: 'ADMIN',
          description: '',
          typeName: '',
          namedType: '',
          args: [],
          deprecated: false,
        ),
      ],
    ),
    _type('String', 'SCALAR'),
    _type(
      'User',
      'OBJECT',
      description: 'Someone with an account.',
      fields: [
        _field('id', 'ID!'),
        _field('nick', 'String', deprecated: true),
        _field('role', 'Role'),
      ],
    ),
  ],
);

Request _graphql({
  String query = 'query User { user { id } }',
  String? variables,
  String? operation,
}) => Request(
  method: 'POST',
  url: 'https://api.test/graphql',
  headers: const [],
  body: query,
  bodyMode: BodyMode.graphQl,
  form: const [],
  graphqlVariables: variables,
  graphqlOperation: operation,
  tests: const [],
  captures: const [],
);

void main() {
  group('draft', () {
    test('a GraphQL request comes back out unchanged', () {
      final draft = RequestDraft();
      addTearDown(draft.dispose);
      final request = _graphql(variables: '{"id": 1}', operation: 'User');
      draft.load(request);
      expect(draft.bodyMode, BodyMode.graphQl);
      expect(draft.graphqlQuery.text, 'query User { user { id } }');
      expect(draft.graphqlVariables.text, '{"id": 1}');
      // The raw body is its own thing, and stays empty.
      expect(draft.body.text, '');

      final out = draft.toRequest();
      expect(out.bodyMode, BodyMode.graphQl);
      expect(out.body, request.body);
      expect(out.graphqlVariables, '{"id": 1}');
      expect(out.graphqlOperation, 'User');
      expect(draft.dirty, isFalse);
    });

    test('edits to the variables and operation count as changes', () {
      final draft = RequestDraft();
      addTearDown(draft.dispose);
      draft.load(_graphql(variables: '{"id": 1}'));
      draft.graphqlVariables.text = '{"id": 2}';
      expect(draft.dirty, isTrue);
      draft.graphqlVariables.text = '{"id": 1}';
      expect(draft.dirty, isFalse);
      draft.graphqlOperation = 'User';
      expect(draft.dirty, isTrue);
    });

    test('an operation the query no longer has is not asked for', () {
      final draft = RequestDraft();
      addTearDown(draft.dispose);
      draft.load(_graphql(operation: 'User'));
      draft.graphqlQuery.text = 'query Users { users { id } }';
      expect(draft.toRequest().graphqlOperation, isNull);
      draft.graphqlQuery.text = 'mutation  User { add { id } }';
      expect(draft.toRequest().graphqlOperation, 'User');
    });

    test('an empty query is no body at all', () {
      final draft = RequestDraft();
      addTearDown(draft.dispose);
      draft.bodyMode = BodyMode.graphQl;
      draft.graphqlVariables.text = '{"id": 1}';
      final out = draft.toRequest();
      expect(out.bodyMode, isNull);
      expect(out.body, isNull);
      expect(out.graphqlVariables, isNull);
    });

    test('switching body type keeps the query for coming back to', () {
      final draft = RequestDraft();
      addTearDown(draft.dispose);
      draft.load(_graphql());
      draft.bodyMode = BodyMode.raw;
      draft.body.text = '{}';
      expect(draft.toRequest().body, '{}');
      expect(draft.toRequest().graphqlVariables, isNull);
      draft.bodyMode = BodyMode.graphQl;
      expect(draft.toRequest().body, 'query User { user { id } }');
    });

    test('a query from the schema replaces the one written, undoably', () {
      final draft = RequestDraft();
      addTearDown(draft.dispose);
      draft.load(_graphql(variables: '{"a": 1}', operation: 'User'));
      final undo = draft.useGraphqlDraft(
        const GraphQlDraft(
          query: 'query Version {\n  version\n}',
          variables: '',
          operation: 'Version',
        ),
      );
      expect(draft.graphqlQuery.text, 'query Version {\n  version\n}');
      expect(draft.graphqlVariables.text, '');
      expect(draft.toRequest().graphqlOperation, isNull);
      undo();
      expect(draft.toRequest().body, 'query User { user { id } }');
      expect(draft.toRequest().graphqlVariables, '{"a": 1}');
      expect(draft.toRequest().graphqlOperation, 'User');
    });
  });

  test('variables are judged once their placeholders are filled', () {
    expect(variablesProblem(''), isNull);
    expect(variablesProblem('{"id": 1}'), isNull);
    expect(variablesProblem('{"id": {{id}}}'), isNull);
    expect(variablesProblem('{"id": }'), 'Variables are not valid JSON');
    expect(
      variablesProblem('[1]'),
      'Variables must be a JSON object, such as {"id": 1}',
    );
  });

  group('session', () {
    test('keeps each server\'s schema and says why one is missing', () async {
      final engine = FakeEngine()..graphqlServerSchema = _schema;
      final store = WorkspaceStore('unused.json', engine: engine);
      final session = GraphqlSession(engine, store);
      addTearDown(session.dispose);

      expect(session.schemaFor('https://api.test/graphql'), isNull);
      expect(await session.fetch(_graphql(), const []), _schema);
      expect(engine.schemaRequests.single.url, 'https://api.test/graphql');
      expect(session.loading, isNull);
      expect(session.schemaFor(' https://api.test/graphql '), _schema);
      expect(session.schemaFor('https://other.test/graphql'), isNull);

      engine.graphqlServerSchema = null;
      final other = Request(
        method: 'POST',
        url: 'other.test/graphql',
        headers: const [],
        form: const [],
        tests: const [],
        captures: const [],
      );
      expect(await session.fetch(other, const []), isNull);
      expect(session.error, contains('Introspection is disabled'));
      // An address typed without a scheme is asked as it would be sent.
      expect(engine.schemaRequests.last.url, 'http://other.test/graphql');
      // The schema already fetched is still there, and opening another
      // request clears only the complaint.
      session.reset();
      expect(session.error, isNull);
      expect(session.schemaFor('https://api.test/graphql'), _schema);
    });
  });

  group('schema browser', () {
    Future<RootField?> Function() show(WidgetTester tester) {
      RootField? picked;
      var done = false;
      return () async {
        if (!done) {
          done = true;
          tester.view.physicalSize = const Size(900, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () async =>
                      picked = await showSchemaBrowser(context, _schema),
                  child: const Text('open'),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
        }
        return picked;
      };
    }

    testWidgets('lists what can be asked for and leads through the types', (
      tester,
    ) async {
      await show(tester)();
      expect(find.text('Queries'), findsOneWidget);
      expect(find.text('Mutations'), findsOneWidget);
      expect(find.text('Subscriptions'), findsNothing);
      expect(find.text('One user.'), findsOneWidget);
      expect(find.byKey(const Key('schema-use-user')), findsOneWidget);
      // Built-in scalars are not worth a row.
      expect(find.byKey(const Key('schema-type-String')), findsNothing);
      expect(find.byKey(const Key('schema-type-User')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('schema-back')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('schema-field-Query.user')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('schema-title'))).data,
        'User',
      );
      expect(find.textContaining('Someone with an account.'), findsOneWidget);
      expect(find.textContaining('Deprecated.'), findsOneWidget);
      // Fields of an ordinary type cannot start a query.
      expect(find.byKey(const Key('schema-use-id')), findsNothing);

      await tester.tap(find.byKey(const Key('schema-field-User.role')));
      await tester.pumpAndSettle();
      expect(find.text('Values'), findsOneWidget);
      expect(find.byKey(const Key('schema-field-Role.ADMIN')), findsOneWidget);

      await tester.tap(find.byKey(const Key('schema-back')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('schema-title'))).data,
        'User',
      );
      await tester.tap(find.byKey(const Key('schema-back')));
      await tester.pumpAndSettle();
      expect(find.text('Queries'), findsOneWidget);
    });

    testWidgets('searches types and fields', (tester) async {
      await show(tester)();
      await tester.enterText(find.byKey(const Key('schema-search')), 'user');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schema-type-User')), findsOneWidget);
      expect(find.byKey(const Key('schema-field-Query.user')), findsOneWidget);
      expect(
        find.byKey(const Key('schema-field-Mutation.addUser')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('schema-field-User.id')), findsNothing);

      await tester.enterText(find.byKey(const Key('schema-search')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schema-no-results')), findsOneWidget);
    });

    testWidgets('hands back the field chosen to write a query for', (
      tester,
    ) async {
      final picked = show(tester);
      await picked();
      await tester.tap(find.byKey(const Key('schema-use-addUser')));
      await tester.pumpAndSettle();
      expect(await picked(), (kind: 'mutation', field: 'addUser'));
      expect(find.byType(SchemaBrowser), findsNothing);
    });
  });

  group('in the app', () {
    late FakeEngine engine;
    late WorkspaceStore store;

    Future<void> open(WidgetTester tester) async {
      engine = FakeEngine();
      store = WorkspaceStore('unused.json', engine: engine);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ReqorbApp(store: store));
      addTearDown(() => tester.pump(const Duration(seconds: 5)));
      await tester.enterText(
        find.byKey(const Key('url')),
        'https://api.test/graphql',
      );
      await tester.tap(find.byKey(const Key('body-tab')));
      await tester.pumpAndSettle();
      // The body types scroll sideways in a pane this narrow.
      await tester.ensureVisible(find.byKey(const Key('body-mode-GraphQL')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('body-mode-GraphQL')));
      await tester.pumpAndSettle();
    }

    Future<void> send(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('send')));
      await tester.pumpAndSettle();
    }

    String text(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

    testWidgets('sends a query with its variables as a POST', (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('graphql-query')),
        'query User(\$id: ID!) { user(id: \$id) { id } }',
      );
      await tester.enterText(
        find.byKey(const Key('graphql-variables')),
        '{"id": {{id}}}',
      );
      await tester.pumpAndSettle();
      // One operation needs no choosing, and placeholders are not faults.
      expect(find.byKey(const Key('graphql-operation')), findsNothing);
      expect(find.byKey(const Key('graphql-problem')), findsNothing);
      expect(find.byKey(const Key('graphql-variables-problem')), findsNothing);

      await send(tester);
      final (request, _) = engine.sends.single;
      // Choosing GraphQL moved the new request off GET.
      expect(request.method, 'POST');
      expect(request.bodyMode, BodyMode.graphQl);
      expect(request.body, 'query User(\$id: ID!) { user(id: \$id) { id } }');
      expect(request.graphqlVariables, '{"id": {{id}}}');
      expect(request.graphqlOperation, isNull);
      expect(find.byKey(const Key('graphql-errors')), findsNothing);
    });

    testWidgets('shows the errors behind a 200', (tester) async {
      await open(tester);
      engine.onSend = (_) async => sentWith(
        response(body: '{"errors":[{"message":"No such user"}]}'),
        graphqlErrors: const ['No such user (at user)'],
      );
      await tester.enterText(
        find.byKey(const Key('graphql-query')),
        '{ user { id } }',
      );
      await send(tester);
      expect(find.text('200 OK'), findsOneWidget);
      expect(
        find.text('The query failed, though the status says 200'),
        findsOneWidget,
      );
      expect(find.text('No such user (at user)'), findsOneWidget);
    });

    testWidgets('points out a broken query and broken variables', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('graphql-query')),
        'query { user {',
      );
      await tester.enterText(
        find.byKey(const Key('graphql-variables')),
        '{"id": }',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('graphql-problem'))).data,
        startsWith('Parse error at 1:1'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('graphql-variables-problem')))
            .data,
        'Variables are not valid JSON',
      );
      // Formatting what cannot be read says so and leaves it alone.
      await tester.tap(find.byKey(const Key('graphql-format')));
      await tester.pump();
      expect(find.textContaining('cannot format the query'), findsOneWidget);
      expect(text(tester, 'graphql-query'), 'query { user {');
    });

    testWidgets('asks which operation to run when there are several', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('graphql-query')),
        'query A { a }\nquery B { b }',
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose which operation to run'), findsOneWidget);

      await tester.tap(find.byKey(const Key('graphql-operation')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('graphql-problem')), findsNothing);
      await send(tester);
      expect(engine.sends.single.$1.graphqlOperation, 'B');

      // Renamed away, the choice no longer stands.
      await tester.enterText(
        find.byKey(const Key('graphql-query')),
        'query A { a }\nquery C { c }',
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose which operation to run'), findsOneWidget);
      await send(tester);
      expect(engine.sends.last.$1.graphqlOperation, isNull);
    });

    testWidgets('formats the query', (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('graphql-query')),
        '  query   A  {  a  }  ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('graphql-format')));
      await tester.pumpAndSettle();
      expect(text(tester, 'graphql-query'), 'query A { a }');
    });

    testWidgets('fetches the schema once and writes a query from it', (
      tester,
    ) async {
      await open(tester);
      engine.graphqlServerSchema = _schema;
      expect(find.text('Fetch schema'), findsOneWidget);
      await tester.tap(find.byKey(const Key('graphql-schema')));
      await tester.pumpAndSettle();
      // The request itself is what is asked with, headers and all.
      expect(engine.schemaRequests.single.url, 'https://api.test/graphql');
      expect(find.byType(SchemaBrowser), findsOneWidget);

      await tester.tap(find.byKey(const Key('schema-use-user')));
      await tester.pumpAndSettle();
      expect(text(tester, 'graphql-query'), 'query Draft {\n  user\n}');
      expect(text(tester, 'graphql-variables'), '{\n  "id": ""\n}');
      // Nothing was overwritten, so there is nothing to undo.
      expect(find.text('Query replaced'), findsNothing);

      // The second look does not ask the server again.
      expect(find.text('Schema'), findsOneWidget);
      await tester.tap(find.byKey(const Key('graphql-schema')));
      await tester.pumpAndSettle();
      expect(engine.schemaRequests, hasLength(1));
      await tester.tap(find.byKey(const Key('schema-use-version')));
      await tester.pumpAndSettle();
      expect(text(tester, 'graphql-query'), 'query Draft {\n  version\n}');
      expect(text(tester, 'graphql-variables'), '');

      // This time a query was replaced, and can be had back.
      expect(find.text('Query replaced'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(text(tester, 'graphql-query'), 'query Draft {\n  user\n}');
      expect(text(tester, 'graphql-variables'), '{\n  "id": ""\n}');

      await tester.tap(find.byKey(const Key('graphql-schema-refresh')));
      await tester.pumpAndSettle();
      expect(engine.schemaRequests, hasLength(2));
      expect(find.byType(SchemaBrowser), findsNothing);
    });

    testWidgets('says why a server gave no schema', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('graphql-schema')));
      await tester.pumpAndSettle();
      expect(find.byType(SchemaBrowser), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('graphql-schema-error'))).data,
        contains('Introspection is disabled'),
      );
      expect(find.text('Fetch schema'), findsOneWidget);
    });

    testWidgets('opens a saved GraphQL request in its editor', (tester) async {
      await open(tester);
      final ref = store.addStandaloneRequest(
        'Users',
        _graphql(
          query: 'query Users { users { id } }\nquery One { user { id } }',
          variables: '{"first": 2}',
          operation: 'One',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Users').first);
      await tester.pumpAndSettle();
      expect(ref, isNotNull);
      await tester.tap(find.byKey(const Key('body-tab')));
      await tester.pumpAndSettle();
      expect(text(tester, 'graphql-variables'), '{"first": 2}');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const Key('graphql-operation')),
            )
            .value,
        'One',
      );
      await send(tester);
      final (request, _) = engine.sends.single;
      expect(request.graphqlOperation, 'One');
      expect(request.graphqlVariables, '{"first": 2}');
    });
  });
}
