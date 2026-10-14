import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/shared/messages.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late WorkspaceStore store;

  Request request(String url) => Request(
    method: 'GET',
    url: url,
    headers: const [],
    form: const [],
    tests: const [],
    captures: const [],
  );

  Future<void> open(WidgetTester tester) async {
    store = WorkspaceStore('unused.json', engine: FakeEngine());
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    store.addStandaloneRequest('Ping', request('https://api.test/ping'));
    store.addStandaloneRequest('Pong', request('https://api.test/pong'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> commandZ(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();
  }

  List<String> names() => [for (final item in store.requests) item.name];

  testWidgets('a deleted request comes back with Command-Z', (tester) async {
    await open(tester);
    await tap(tester, find.byTooltip('Request actions').first);
    await tap(tester, find.byKey(const Key('delete-request')));
    expect(names(), ['Pong']);

    await commandZ(tester);
    expect(names(), ['Ping', 'Pong'], reason: 'back where it was');
    // Once only: a second press has nothing left to undo.
    await commandZ(tester);
    expect(names(), ['Ping', 'Pong']);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('once its message is replaced, Command-Z leaves it gone', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.byTooltip('Request actions').first);
    await tap(tester, find.byKey(const Key('delete-request')));
    // The offer stays until something else is said.
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Undo'), findsOneWidget);
    showMessage(tester.element(find.byType(Scaffold).first), 'Saved');
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
    await commandZ(tester);
    expect(names(), ['Pong']);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('a cleared session can be put back', (tester) async {
    await open(tester);
    final exchange = Exchange(
      startedMs: 0,
      request: request('https://api.test/ping'),
      response: const Response(
        status: 200,
        statusText: 'OK',
        httpVersion: 'HTTP/1.1',
        headers: [],
        body: '',
        sizeBytes: 0,
        elapsedMs: 1,
      ),
    );
    store.addExchanges([exchange]);
    await tester.pumpAndSettle();
    await tap(tester, find.byTooltip('Session actions'));
    await tap(tester, find.byKey(const Key('session-clear')));
    expect(store.session, isEmpty);
    await tap(tester, find.text('Undo'));
    expect(store.session, [exchange]);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });
}
