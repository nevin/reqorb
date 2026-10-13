import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
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

  /// The app with two saved requests, Ping and Pong.
  Future<void> open(WidgetTester tester) async {
    store = WorkspaceStore('unused.json', engine: FakeEngine());
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    store.addStandaloneRequest('Ping', request('https://api.test/ping'));
    store.addStandaloneRequest('Pong', request('https://api.test/pong'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// The names on the tabs, left to right.
  List<String> tabs(WidgetTester tester) => [
    for (var i = 0; find.byKey(Key('tab-name-$i')).evaluate().isNotEmpty; i++)
      tester
          .widget<RichText>(find.byKey(Key('tab-name-$i')))
          .text
          .toPlainText(),
  ];

  String url(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const Key('url'))).controller!.text;

  testWidgets('a saved request opens in the untouched first tab', (
    tester,
  ) async {
    await open(tester);
    expect(tabs(tester).length, 1);
    await tap(tester, find.text('Ping'));
    expect(tabs(tester), ['Ping']);
    expect(url(tester), 'https://api.test/ping');
  });

  testWidgets('each request gets a tab, and keeps what was typed in it', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.text('Ping'));
    await tap(tester, find.text('Pong'));
    expect(tabs(tester), ['Ping', 'Pong']);
    expect(url(tester), 'https://api.test/pong');

    await tester.enterText(find.byKey(const Key('url')), 'https://changed');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tab-dirty-1')), findsOneWidget);

    await tap(tester, find.byKey(const Key('tab-0')));
    expect(url(tester), 'https://api.test/ping');
    await tap(tester, find.byKey(const Key('tab-1')));
    expect(url(tester), 'https://changed');
  });

  testWidgets('opening a request that is already open goes to its tab', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.text('Ping'));
    await tap(tester, find.text('Pong'));
    // The sidebar's row, not the title of the open request.
    await tap(tester, find.text('Ping').first);
    expect(tabs(tester), ['Ping', 'Pong']);
    expect(url(tester), 'https://api.test/ping');
  });

  testWidgets('each tab comes back to the part it was showing', (tester) async {
    await open(tester);
    await tap(tester, find.text('Ping'));
    await tap(tester, find.byKey(const Key('auth-tab')));
    await tap(tester, find.text('Pong'));
    expect(find.byKey(const Key('auth-kind')), findsNothing);
    await tap(tester, find.byKey(const Key('headers-tab')));

    await tap(tester, find.byKey(const Key('tab-0')));
    expect(find.byKey(const Key('auth-kind')), findsOneWidget);
    await tap(tester, find.byKey(const Key('tab-1')));
    expect(find.byKey(const Key('auth-kind')), findsNothing);
    expect(find.byKey(const Key('headers-bulk-toggle')), findsOneWidget);
  });

  testWidgets('a new tab starts empty, and an empty one is not doubled', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.text('Ping'));
    await tap(tester, find.byKey(const Key('tab-new')));
    expect(tabs(tester), ['Ping', 'Untitled']);
    expect(url(tester), '');
    await tap(tester, find.byKey(const Key('tab-new')));
    expect(tabs(tester).length, 2);
    // What is opened next takes the empty tab.
    await tap(tester, find.text('Pong'));
    expect(tabs(tester), ['Ping', 'Pong']);
  });

  testWidgets('closing a tab with unsaved edits asks first', (tester) async {
    await open(tester);
    await tap(tester, find.text('Ping'));
    await tap(tester, find.text('Pong'));
    await tester.enterText(find.byKey(const Key('url')), 'https://changed');
    await tester.pumpAndSettle();

    await tap(tester, find.byKey(const Key('tab-close-1')));
    expect(find.text('Save changes?'), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect(tabs(tester), ['Ping', 'Pong']);

    await tap(tester, find.byKey(const Key('tab-close-1')));
    await tap(tester, find.byKey(const Key('save-changes')));
    expect(tabs(tester), ['Ping']);
    expect(url(tester), 'https://api.test/ping');
    expect(
      store.itemAt(RequestRef.standalone(1))!.request!.url,
      'https://changed',
    );
  });

  testWidgets('discarding leaves the saved request as it was', (tester) async {
    await open(tester);
    await tap(tester, find.text('Ping'));
    await tester.enterText(find.byKey(const Key('url')), 'https://changed');
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('tab-close-0')));
    await tap(tester, find.byKey(const Key('discard-changes')));
    // The last tab makes way for an empty one.
    expect(tabs(tester), ['Untitled']);
    expect(
      store.itemAt(RequestRef.standalone(0))!.request!.url,
      'https://api.test/ping',
    );
  });

  testWidgets('a tab whose request is deleted carries on unsaved', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.text('Ping'));
    await tap(tester, find.text('Pong'));
    await tap(tester, find.byKey(const Key('tab-0')));
    await tap(tester, find.byTooltip('Request actions').first);
    await tap(tester, find.byKey(const Key('delete-request')));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    // Ping's tab is kept, with what was in it; Pong's still knows its own.
    expect(tabs(tester), ['Ping', 'Pong']);
    expect(url(tester), 'https://api.test/ping');
    expect(find.byKey(const Key('tab-dirty-0')), findsNothing);
    await tap(tester, find.byKey(const Key('tab-1')));
    expect(url(tester), 'https://api.test/pong');
    await tester.enterText(find.byKey(const Key('url')), 'https://changed');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tab-dirty-1')), findsOneWidget);
  });
}
