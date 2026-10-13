import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/editor/code_formatter.dart';
import 'package:reqorb/editor/folding.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/graphql/graphql_complete.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

/// The text of each token with its kind, for reading in an expectation.
List<(String, TokenKind)> kinds(String text, CodeLanguage language) => [
  for (final token in tokenize(text, language))
    (text.substring(token.start, token.end), token.kind),
];

GraphQlField _field(
  String name,
  String type, {
  List<GraphQlArg> args = const [],
}) => GraphQlField(
  name: name,
  description: '',
  typeName: type,
  namedType: type.replaceAll(RegExp(r'[\[\]!]'), ''),
  args: args,
  deprecated: false,
);

GraphQlType _type(
  String name,
  String kind, {
  List<GraphQlField> fields = const [],
  List<String> members = const [],
}) => GraphQlType(
  name: name,
  kind: kind,
  description: '',
  fields: fields,
  members: members,
);

final _schema = GraphQlSchema(
  queryType: 'Query',
  mutationType: 'Mutation',
  subscriptionType: '',
  types: [
    _type(
      'Query',
      'OBJECT',
      fields: [
        _field(
          'user',
          'User',
          args: const [
            GraphQlArg(
              name: 'id',
              description: '',
              typeName: 'ID!',
              defaultValue: '',
            ),
          ],
        ),
        _field('users', '[User!]!'),
        _field('search', '[Result!]!'),
      ],
    ),
    _type('Mutation', 'OBJECT', fields: [_field('addUser', 'User')]),
    _type(
      'User',
      'OBJECT',
      fields: [
        _field('name', 'String!'),
        _field('email', 'String'),
        _field('friends', '[User!]!'),
      ],
    ),
    _type('Result', 'UNION', members: ['User', 'Team']),
    _type('Team', 'OBJECT', fields: [_field('title', 'String!')]),
  ],
);

/// The labels offered with the caret at the `|` in [query].
List<String>? offered(String query, {bool asked = false}) {
  final caret = query.indexOf('|');
  return completeGraphql(
    _schema,
    query.replaceFirst('|', ''),
    caret,
    asked: asked,
  )?.items.map((item) => item.label).toList();
}

void main() {
  group('colouring', () {
    test('tells JSON keys from values', () {
      expect(kinds('{"a": "b", "n": -1.5e3, "t": true}', CodeLanguage.json), [
        ('"a"', TokenKind.key),
        ('"b"', TokenKind.string),
        ('"n"', TokenKind.key),
        ('-1.5e3', TokenKind.number),
        ('"t"', TokenKind.key),
        ('true', TokenKind.keyword),
      ]);
    });

    test('picks out variables wherever they are', () {
      expect(
        kinds('{"url": "{{base}}/x", "n": {{count}}}', CodeLanguage.json),
        [
          ('"url"', TokenKind.key),
          ('"', TokenKind.string),
          ('{{base}}', TokenKind.variable),
          ('/x"', TokenKind.string),
          ('"n"', TokenKind.key),
          ('{{count}}', TokenKind.variable),
        ],
      );
      expect(kinds('Bearer {{token}}', CodeLanguage.plain), [
        ('{{token}}', TokenKind.variable),
      ]);
    });

    test('reads a GraphQL query', () {
      expect(
        kinds(
          'query Q(\$id: ID!) { # one\n  user(id: \$id) @skip { name } }',
          CodeLanguage.graphql,
        ),
        [
          ('query', TokenKind.keyword),
          ('Q', TokenKind.type),
          (r'$id', TokenKind.parameter),
          ('ID', TokenKind.type),
          ('# one', TokenKind.comment),
          ('id', TokenKind.key),
          (r'$id', TokenKind.parameter),
          ('@skip', TokenKind.keyword),
        ],
      );
    });

    test('reads tags, attributes and comments in XML', () {
      expect(kinds('<a href="x"><!-- c --></a>', CodeLanguage.xml), [
        ('<a', TokenKind.tag),
        ('href', TokenKind.attribute),
        ('"x"', TokenKind.string),
        ('>', TokenKind.tag),
        ('<!-- c -->', TokenKind.comment),
        ('</a', TokenKind.tag),
        ('>', TokenKind.tag),
      ]);
    });

    test('guesses the language of an unlabelled body', () {
      expect(CodeLanguage.sniff('  {"a":1}'), CodeLanguage.json);
      expect(CodeLanguage.sniff('<html>'), CodeLanguage.xml);
      expect(CodeLanguage.sniff('hello'), CodeLanguage.plain);
      expect(
        CodeLanguage.ofContentType('application/problem+json'),
        CodeLanguage.json,
      );
      expect(CodeLanguage.ofContentType('text/html'), CodeLanguage.xml);
    });

    test('finds the bracket matching the one beside the caret', () {
      final code = CodeController(
        text: '{"a": [1, "]"]}',
        language: CodeLanguage.json,
      );
      code.selection = const TextSelection.collapsed(offset: 1);
      expect(code.matchingBrackets(), (0, 14));
      // The bracket inside the string is only a character.
      code.selection = const TextSelection.collapsed(offset: 7);
      expect(code.matchingBrackets(), (6, 13));
      code.selection = const TextSelection.collapsed(offset: 3);
      expect(code.matchingBrackets(), isNull);
    });

    testWidgets('the coloured text is still the same text', (tester) async {
      final code = CodeController(
        text: '{\n  "a": [1, 2],\n  "b": "{{x}}"\n}',
        language: CodeLanguage.json,
      );
      code.selection = const TextSelection.collapsed(offset: 1);
      code.mark(const [TextRange(start: 4, end: 9)], 0);
      late TextSpan span;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              span = code.buildTextSpan(context: context, withComposing: false);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(span.toPlainText(), code.text);
      expect(span.children!.length, greaterThan(8));
    });
  });

  group('typing', () {
    final formatter = CodeFormatter(pairs: () => true);

    /// Types [typed] at the `|` in [before]; the result with its caret.
    String type(String before, String typed) {
      final at = before.indexOf('|');
      final text = before.replaceFirst('|', '');
      final old = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: at),
      );
      final now = formatter.formatEditUpdate(
        old,
        TextEditingValue(
          text: text.replaceRange(at, at, typed),
          selection: TextSelection.collapsed(offset: at + typed.length),
        ),
      );
      return now.text.replaceRange(
        now.selection.baseOffset,
        now.selection.baseOffset,
        '|',
      );
    }

    test('a new line keeps the indentation', () {
      expect(type('  "a": 1,|', '\n'), '  "a": 1,\n  |');
    });

    test('a new line after a bracket goes one level in', () {
      expect(type('{|', '\n'), '{\n  |');
      expect(type('  [|]', '\n'), '  [\n    |\n  ]');
    });

    test('brackets and quotes come in pairs', () {
      expect(type('|', '{'), '{|}');
      expect(type('{|}', '"'), '{"|"}');
      // Not in the middle of a word.
      expect(type('|abc', '['), '[|abc');
      expect(type("don|", '"'), 'don"|');
    });

    test('a closing bracket already there is stepped over', () {
      expect(type('{"a"|}', '}'), '{"a"}|');
      expect(type('"a|"', '"'), '"a"|');
    });

    test('a pasted block is left alone', () {
      expect(type('|', '{"a": 1}'), '{"a": 1}|');
    });

    test('rubbing out an empty pair takes both', () {
      const old = TextEditingValue(
        text: 'a{}',
        selection: TextSelection.collapsed(offset: 2),
      );
      final now = formatter.formatEditUpdate(
        old,
        const TextEditingValue(
          text: 'a}',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(now.text, 'a');
    });

    test('plain text gets no pairs', () {
      final plain = CodeFormatter(pairs: () => false);
      const old = TextEditingValue(
        selection: TextSelection.collapsed(offset: 0),
      );
      final now = plain.formatEditUpdate(
        old,
        const TextEditingValue(
          text: '"',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(now.text, '"');
    });
  });

  group('GraphQL completion', () {
    test('offers the fields of the type being selected from', () {
      expect(offered('{ u| }'), ['user', 'users']);
      expect(offered('{ user(id: 1) { e| } }'), [
        'email',
        'name',
        'friends',
        '__typename',
      ]);
      expect(offered('query Q { users { friends { na| } } }'), [
        'name',
        '__typename',
      ]);
      expect(offered('mutation { ad| }'), ['addUser']);
    });

    test('says nothing until a letter is typed, unless asked', () {
      expect(offered('{ user { | } }'), isNull);
      expect(offered('{ user { | } }', asked: true), [
        'name',
        'email',
        'friends',
        '__typename',
      ]);
    });

    test('offers the arguments of the field being called', () {
      expect(offered('{ user(i|) }'), ['id']);
      // A value is being written here, not a name.
      expect(offered('{ user(id: a|) }'), isNull);
    });

    test('follows fragments and unions', () {
      expect(offered('{ search { ... on Team { t| } } }'), [
        'title',
        '__typename',
      ]);
      expect(offered('fragment F on User { em| }'), ['email']);
      expect(offered('{ search { | } }', asked: true), [
        '... on User',
        '... on Team',
        '__typename',
      ]);
    });

    test('is not confused by braces in strings and comments', () {
      expect(offered('{ # }\n user(id: "}") { n| } }'), [
        'name',
        'friends',
        '__typename',
      ]);
    });
  });

  group('in the editor', () {
    late CodeController code;

    Future<void> show(
      WidgetTester tester, {
      String text = '',
      CodeLanguage language = CodeLanguage.json,
      bool readOnly = false,
      List<String> variables = const [],
    }) async {
      code = CodeController(text: text);
      addTearDown(code.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 300,
              child: CodeEditor(
                name: 'code',
                controller: code,
                language: language,
                readOnly: readOnly,
                variables: variables,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('searches, steps through matches and clears up', (
      tester,
    ) async {
      await show(tester, text: '{"name": "a", "Name": "b"}\n' * 40);
      await tester.tap(find.byKey(const Key('code-find')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('code-find-field')), 'name');
      await tester.pumpAndSettle();
      Text count() => tester.widget(find.byKey(const Key('code-find-count')));
      expect(count().data, '1 of 80');
      expect(code.found.length, 80);

      await tester.tap(find.byKey(const Key('code-find-next')));
      await tester.pumpAndSettle();
      expect(count().data, '2 of 80');
      await tester.tap(find.byKey(const Key('code-find-previous')));
      await tester.tap(find.byKey(const Key('code-find-previous')));
      await tester.pumpAndSettle();
      expect(count().data, '80 of 80');
      // The last match is far down: the text scrolled to show it.
      final field = tester.widget<TextField>(find.byKey(const Key('code')));
      expect(field.scrollController!.offset, greaterThan(0));

      await tester.enterText(find.byKey(const Key('code-find-field')), 'zzz');
      await tester.pumpAndSettle();
      expect(count().data, 'None');

      await tester.tap(find.byKey(const Key('code-find-close')));
      await tester.pumpAndSettle();
      expect(code.found, isEmpty);
      expect(find.byKey(const Key('code-find-field')), findsNothing);
    });

    testWidgets('opens the search from the keyboard', (tester) async {
      await show(tester, text: 'one two one', readOnly: true);
      await tester.tap(find.byKey(const Key('code')));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-find-field')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('code-find-field')), 'one');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(code.current, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-find-field')), findsNothing);
    });

    testWidgets('completes a variable after two braces', (tester) async {
      await show(tester, variables: ['base_url', 'token', 'user_id']);
      await tester.enterText(find.byKey(const Key('code')), '{"a": "{{');
      await tester.pumpAndSettle();
      expect(find.text('base_url'), findsOneWidget);
      expect(find.text('token'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('code')), '{"a": "{{us');
      await tester.pumpAndSettle();
      expect(find.text('token'), findsNothing);
      await tester.tap(find.byKey(const Key('code-suggestion-0')));
      await tester.pumpAndSettle();
      expect(code.text, '{"a": "{{user_id}}');
      expect(find.byKey(const Key('code-suggestion-0')), findsNothing);
    });

    testWidgets('picks a completion with the keyboard', (tester) async {
      await show(tester, variables: ['alpha', 'beta']);
      await tester.enterText(find.byKey(const Key('code')), '{{');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(code.text, '{{beta}}');
    });

    testWidgets('tab indents, and takes the indent off again', (tester) async {
      await show(tester, text: 'a\nb');
      await tester.tap(find.byKey(const Key('code')));
      await tester.pump();
      code.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(code.text, '  a\n  b');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(code.text, 'a\nb');
    });

    testWidgets('typing in an empty, unlabelled editor still pairs brackets', (
      tester,
    ) async {
      code = CodeController();
      addTearDown(code.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeEditor(name: 'code', controller: code),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('code')));
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '{',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      expect(code.text, '{}');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '{\n}',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      expect(code.text, '{\n  \n}');
      expect(code.selection.baseOffset, 4);
      // Now that it looks like JSON, it is coloured as JSON.
      expect(code.shownAs, CodeLanguage.json);
    });

    Future<void> find_(WidgetTester tester, String query) async {
      await tester.tap(find.byKey(const Key('code-find')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('code-find-field')), query);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('code-replace-toggle')));
      await tester.pumpAndSettle();
    }

    testWidgets('replaces matches one at a time', (tester) async {
      await show(tester, text: 'cat Cat cat', language: CodeLanguage.plain);
      await find_(tester, 'cat');
      await tester.enterText(
        find.byKey(const Key('code-replace-field')),
        'concat',
      );
      await tester.tap(find.byKey(const Key('code-replace-one')));
      await tester.pumpAndSettle();
      // On to the next one, not the "cat" inside what was just put in.
      expect(code.text, 'concat Cat cat');
      expect(code.found[code.current].start, 7);
      await tester.tap(find.byKey(const Key('code-replace-one')));
      await tester.pumpAndSettle();
      expect(code.text, 'concat concat cat');
      await tester.tap(find.byKey(const Key('code-replace-one')));
      await tester.pumpAndSettle();
      expect(code.text, 'concat concat concat');
    });

    testWidgets('replaces every match at once', (tester) async {
      await show(tester, text: 'a-b-a\n' * 3000, language: CodeLanguage.plain);
      await find_(tester, 'A');
      await tester.enterText(find.byKey(const Key('code-replace-field')), '');
      await tester.tap(find.byKey(const Key('code-replace-all')));
      await tester.pumpAndSettle();
      // More than the search counts, and all of them gone.
      expect(code.text, '-b-\n' * 3000);
      expect(code.found, isEmpty);
    });

    testWidgets('code that is only shown offers no replace', (tester) async {
      await show(tester, text: 'one two', readOnly: true);
      await tester.tap(find.byKey(const Key('code-find')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-replace-toggle')), findsNothing);
    });

    testWidgets('tells whoever shows it of every change', (tester) async {
      final heard = <String>[];
      code = CodeController(text: 'a a');
      addTearDown(code.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeEditor(
              name: 'code',
              controller: code,
              language: CodeLanguage.pairs,
              onChanged: heard.add,
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(const Key('code')), 'k=(');
      // Lines of names and values are not code: nothing is paired.
      expect(heard, ['k=(']);
    });

    testWidgets('code that is only shown cannot be changed', (tester) async {
      await show(tester, text: '{"a": 1}', readOnly: true);
      final field = tester.widget<TextField>(find.byKey(const Key('code')));
      expect(field.readOnly, isTrue);
      expect(find.byKey(const Key('code-gutter')), findsOneWidget);
    });
  });

  group('folding', () {
    const json =
        '{\n  "a": {\n    "b": [\n      1,\n      "}"\n    ]\n  },\n  "c": 2\n}';

    FoldedText fold(Set<int> lines) {
      final regions = foldRegions(json, tokenize(json, CodeLanguage.json));
      return foldText(json, regions, {
        for (final region in regions)
          if (lines.contains(region.line)) region.open,
      });
    }

    test('finds the regions that span lines', () {
      final regions = foldRegions(json, tokenize(json, CodeLanguage.json));
      // The bracket in the string does not close anything.
      expect([for (final r in regions) r.line], [1, 2, 3]);
      expect(json[regions[2].close], ']');
    });

    test('nothing folded shows everything', () {
      final shown = fold({});
      expect(shown.text, json);
      expect(shown.numbers, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(shown.folds, [
        false,
        false,
        false,
        null,
        null,
        null,
        null,
        null,
        null,
      ]);
    });

    test('a folded region leaves a gap in the numbers', () {
      final shown = fold({2});
      expect(shown.text, '{\n  "a": {…},\n  "c": 2\n}');
      expect(shown.numbers, [1, 2, 8, 9]);
      expect(shown.folds, [false, true, null, null]);
    });

    test('a fold inside a folded one stays out of sight', () {
      final shown = fold({1, 3});
      expect(shown.text, '{…}');
      expect(shown.numbers, [1]);
    });

    testWidgets('a response folds from its gutter, and a search unfolds it', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: CodeView(name: 'view', text: json),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      String shown() => tester
          .widget<TextField>(find.byKey(const Key('view')))
          .controller!
          .text;
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final gutter = tester.getRect(find.byKey(const Key('view-gutter')));
      // The middle of the second line, in the gutter.
      final line = editable.getLocalRectForCaret(
        TextPosition(offset: json.indexOf('"a"')),
      );
      final at = Offset(
        gutter.right - 9,
        editable.localToGlobal(line.center).dy,
      );
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(shown(), '{\n  "a": {…},\n  "c": 2\n}');
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(shown(), json);

      await tester.tapAt(at);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-find')));
      await tester.pumpAndSettle();
      expect(shown(), json);
    });
  });

  group('lines of names and values', () {
    test('colours variables as they are written', () {
      expect(
        kinds(
          '# off=1\nsecret token = abc\nbase_url=https://x',
          CodeLanguage.pairs,
        ),
        [
          ('# off=1', TokenKind.comment),
          ('secret', TokenKind.keyword),
          ('token', TokenKind.key),
          ('base_url', TokenKind.key),
        ],
      );
    });

    test('colours a header up to its colon only', () {
      expect(kinds('X-Id: a:b={{id}}', CodeLanguage.pairs), [
        ('X-Id', TokenKind.key),
        ('{{id}}', TokenKind.variable),
      ]);
    });

    test('colours checks', () {
      expect(
        kinds('status == 200\nbody.name contains "x"', CodeLanguage.checks),
        [
          ('status', TokenKind.type),
          ('==', TokenKind.keyword),
          ('200', TokenKind.number),
          ('body', TokenKind.type),
          ('contains', TokenKind.keyword),
          ('"x"', TokenKind.string),
        ],
      );
    });
  });

  testWidgets('the app completes variables of the active environment', (
    tester,
  ) async {
    final store = WorkspaceStore('unused.json', engine: FakeEngine());
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    store.merge(
      const ImportResult(
        source: 'test',
        warnings: [],
        collections: [],
        environments: [
          Environment(
            name: 'Local',
            variables: [
              Variable(
                key: 'base_url',
                value: 'http://localhost',
                enabled: true,
                secret: false,
              ),
            ],
          ),
        ],
      ),
    );
    store.setActiveEnvironment('Local');
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));

    await tester.tap(find.text('Body'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('body-mode-raw')));
    await tester.tap(find.byKey(const Key('body-mode-raw')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('body')), '{"at": "{{ba');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body-suggestion-0')));
    await tester.pumpAndSettle();
    final body = tester.widget<TextField>(find.byKey(const Key('body')));
    expect(body.controller!.text, '{"at": "{{base_url}}');
  });
}
