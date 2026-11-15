import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late WorkspaceStore store;
  late FakeEngine engine;

  Request request(String url, {String method = 'GET'}) => Request(
    method: method,
    url: url,
    headers: const [],
    form: const [],
    tests: const [],
    captures: const [],
  );

  /// The app with one saved request, Ping.
  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
    store = WorkspaceStore('unused.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 5)));
    store.addStandaloneRequest('Ping', request('https://api.test/ping'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Presses [key] with Control held, and Shift too when asked.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();
  }

  /// Chooses [command] in the menu bar, as the platform reports it.
  Future<void> choose(WidgetTester tester, String command) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'reqorb/menu',
      const StandardMethodCodec().encodeMethodCall(MethodCall('run', command)),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  String url(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const Key('url'))).controller!.text;

  testWidgets('the menu bar does what the app can do', (tester) async {
    await open(tester);
    await tap(tester, find.text('Ping'));
    await choose(tester, 'newRequest');
    expect(find.byKey(const Key('tab-1')), findsOneWidget);
    await choose(tester, 'previousTab');
    expect(url(tester), 'https://api.test/ping');
    await choose(tester, 'closeTab');
    expect(find.byKey(const Key('tab-1')), findsNothing);
    await choose(tester, 'reopenTab');
    expect(url(tester), 'https://api.test/ping');

    await choose(tester, 'sidebar');
    expect(find.byKey(const Key('show-sidebar')), findsOneWidget);
    await choose(tester, 'sidebar');
    expect(find.byKey(const Key('show-sidebar')), findsNothing);

    await choose(tester, 'shortcuts');
    expect(find.byKey(const Key('shortcuts')), findsOneWidget);
    // Over a dialog the menu bar is still there, but leaves the page alone.
    await choose(tester, 'newRequest');
    expect(find.byKey(const Key('tab-1')), findsNothing);
    await tap(tester, find.text('Close'));

    // A name the app does not know is ignored.
    await choose(tester, 'nothing');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shortcuts are listed from the keyboard', (tester) async {
    await open(tester);
    await press(tester, LogicalKeyboardKey.slash);
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Reopen the tab closed last'), findsOneWidget);
  });

  testWidgets('code is made larger and smaller, within limits', (tester) async {
    await open(tester);
    expect(store.settings.fontSize, 13);
    await press(tester, LogicalKeyboardKey.equal);
    await press(tester, LogicalKeyboardKey.equal);
    expect(store.settings.fontSize, 15);
    await press(tester, LogicalKeyboardKey.minus);
    expect(store.settings.fontSize, 14);
    await press(tester, LogicalKeyboardKey.digit0);
    expect(store.settings.fontSize, 13);
    for (var i = 0; i < 10; i++) {
      await press(tester, LogicalKeyboardKey.minus);
    }
    expect(store.settings.fontSize, 9);
    // The settings are saved a moment after the last change.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a right click on a saved request offers what can be done', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Ping'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    // Not opened by the click itself.
    expect(url(tester), isNot('https://api.test/ping'));
    await tap(tester, find.byKey(const Key('duplicate-request')));
    expect(store.requests.length, 2);

    await tester.tap(find.text('Ping').first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('open-request')));
    expect(url(tester), 'https://api.test/ping');
  });

  testWidgets('a right click on a collection offers what can be done', (
    tester,
  ) async {
    await open(tester);
    store.addCollection('Billing');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Billing'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('run-collection')), findsOneWidget);
    await tap(tester, find.byKey(const Key('delete-collection')));
    expect(store.collections, isEmpty);
  });

  testWidgets('a curl command pasted as the address fills the request in', (
    tester,
  ) async {
    await open(tester);
    engine.importResult = ImportResult(
      source: 'curl',
      collections: [
        Collection(
          unreviewed: false,
          name: 'Pasted',
          variables: const [],
          items: [
            Item(
              name: 'POST /orders',
              request: request('https://api.test/orders', method: 'POST'),
              items: const [],
            ),
          ],
        ),
      ],
      environments: const [],
      warnings: const [],
    );
    // As it arrives in a field of one line: the line breaks gone, the
    // backslashes that continued them left.
    await tester.enterText(
      find.byKey(const Key('url')),
      r"curl 'https://api.test/orders' \  -X POST \  -H 'Accept: */*'",
    );
    await tester.pumpAndSettle();
    expect(engine.importedTexts, [
      "curl 'https://api.test/orders'  -X POST  -H 'Accept: */*'",
    ]);
    expect(url(tester), 'https://api.test/orders');
    expect(find.text('Filled in from the curl command.'), findsOneWidget);
    expect(store.collections, isEmpty);

    // One that cannot be read is left as it was pasted, and said so.
    engine.importResult = null;
    await tester.enterText(find.byKey(const Key('url')), 'curl --nonsense x');
    await tester.pumpAndSettle();
    expect(url(tester), 'curl --nonsense x');
    expect(find.text('That curl command could not be read.'), findsOneWidget);
  });

  testWidgets('a curl command typed letter by letter is left alone', (
    tester,
  ) async {
    await open(tester);
    for (final text in ['c', 'cu', 'cur', 'curl', 'curl ', 'curl h']) {
      await tester.enterText(find.byKey(const Key('url')), text);
    }
    await tester.pumpAndSettle();
    expect(engine.importedTexts, isEmpty);
  });
}
