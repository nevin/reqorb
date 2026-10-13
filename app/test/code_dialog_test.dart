import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/editor/syntax.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/request/code_dialog.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/transfer/export_actions.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late WorkspaceStore store;

  /// The app with a request for `https://api.test/ping` in its only tab.
  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
    store = WorkspaceStore('unused.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    await tester.enterText(
      find.byKey(const Key('url')),
      'https://api.test/ping',
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// What the dialog is showing as code.
  String shown(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('generated-code')))
      .controller!
      .text;

  Future<void> choose(WidgetTester tester, String label) async {
    await tap(tester, find.byKey(const Key('code-language')));
    await tap(tester, find.text(label).last);
  }

  testWidgets('the request is shown as code, in the language chosen', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.byKey(const Key('code')));
    // A tab is shown at the width an editor gives it.
    expect(shown(tester), '# curl\n    GET "https://api.test/ping"');

    await choose(tester, 'Python · requests');
    expect(shown(tester), '# python\n    GET "https://api.test/ping"');
    expect(engine.coded.last.$3, CodeTarget.python);

    // The choice is kept for the next time.
    await tap(tester, find.byKey(const Key('code-close')));
    expect(find.byKey(const Key('code-language')), findsNothing);
    await tap(tester, find.byKey(const Key('code')));
    expect(shown(tester), startsWith('# python'));
    await choose(tester, 'curl');
  });

  testWidgets('the code is written with the variables in force', (
    tester,
  ) async {
    await open(tester);
    final index = store.addEnvironment();
    store.updateEnvironment(
      index,
      const Environment(
        name: 'Local',
        variables: [
          Variable(key: 'base', value: 'x', enabled: true, secret: false),
        ],
      ),
    );
    store.setActiveEnvironment('Local');
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('code')));
    final (request, variables, _) = engine.coded.last;
    expect(request.url, 'https://api.test/ping');
    expect(variables.map((v) => v.key), contains('base'));
  });

  testWidgets('the code can be copied and saved to a file', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final saved = <String, String>{};
    final realSaver = fileSaver;
    fileSaver = ({required fileName, required bytes}) async {
      saved[fileName] = utf8.decode(bytes);
      return fileName;
    };
    addTearDown(() => fileSaver = realSaver);

    await open(tester);
    await tap(tester, find.byKey(const Key('code')));
    await choose(tester, 'Go · net/http');
    await tap(tester, find.byKey(const Key('code-copy')));
    // Copied as written, less the line break that ends it.
    expect(copied, '// go\n\tGET "https://api.test/ping"');
    expect(find.text('Code copied'), findsOneWidget);

    await tap(tester, find.byKey(const Key('code-save')));
    expect(saved, {'request.go': '// go\n\tGET "https://api.test/ping"\n'});
    await choose(tester, 'curl');
  });

  testWidgets('a request without a URL has no code to show', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('url')), '');
    await tap(tester, find.byKey(const Key('code')));
    expect(find.byKey(const Key('code-language')), findsNothing);
    expect(find.text('Enter a URL to write the request as code'), findsOne);
  });

  testWidgets('WebSocket and gRPC requests offer no code', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('code')), findsOneWidget);
    await tap(tester, find.byKey(const Key('method')));
    await tap(tester, find.text('WS').last);
    expect(find.byKey(const Key('code')), findsNothing);
  });

  group('colouring generated code', () {
    List<(String, TokenKind)> tokens(String text, CodeLanguage language) => [
      for (final token in tokenize(text, language))
        (text.substring(token.start, token.end), token.kind),
    ];

    test('a C-like language', () {
      expect(
        tokens(
          '// note\nimport Foundation\nlet n = 5 // five\n'
          'request.add("it\'s //", forField: `raw`)',
          CodeLanguage.source,
        ),
        [
          ('// note', TokenKind.comment),
          ('import', TokenKind.keyword),
          ('Foundation', TokenKind.type),
          ('let', TokenKind.keyword),
          ('5', TokenKind.number),
          ('// five', TokenKind.comment),
          ('"it\'s //"', TokenKind.string),
          ('`raw`', TokenKind.string),
        ],
      );
    });

    test('a scripting language, and a curl command', () {
      expect(
        tokens(
          '# note\nimport requests\nurl = "http://h/#x"\nprint(None)',
          CodeLanguage.script,
        ),
        [
          ('# note', TokenKind.comment),
          ('import', TokenKind.keyword),
          ('"http://h/#x"', TokenKind.string),
          ('print', TokenKind.keyword),
          ('None', TokenKind.keyword),
        ],
      );
      // A body runs over several lines, with the shell's way of quoting.
      expect(tokens("curl -d '{\n  1\n}' 'it'\\''s'", CodeLanguage.script), [
        ("'{\n  1\n}'", TokenKind.string),
        ("'it'", TokenKind.string),
        ("\\'", TokenKind.string),
        ("'s'", TokenKind.string),
      ]);
    });

    test('every language has a colouring', () {
      expect(codeLanguageOf(CodeTarget.typeScript), CodeLanguage.javascript);
      expect(codeLanguageOf(CodeTarget.curl), CodeLanguage.script);
      expect(codeLanguageOf(CodeTarget.rust), CodeLanguage.source);
    });
  });
}
