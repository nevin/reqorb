import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/shared/split_view.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;
  late WorkspaceStore store;

  Future<void> open(WidgetTester tester) async {
    engine = FakeEngine();
    store = WorkspaceStore('/tmp/workspace.json', engine: engine);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReqorbApp(store: store));
    addTearDown(() => tester.pump(const Duration(seconds: 1)));
    await tester.tap(find.byKey(const Key('settings')));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String key, String option) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> toggle(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('every general setting is saved as it is changed', (
    tester,
  ) async {
    await open(tester);
    for (final section in const ['Request', 'Headers', 'User interface']) {
      // "Headers" is also a tab of the request behind the dialog.
      expect(find.text(section), findsWidgets);
    }

    await pick(tester, 'settings-http', 'HTTP/1');
    await tester.enterText(find.byKey(const Key('settings-timeout')), '30');
    await tester.enterText(find.byKey(const Key('settings-max-size')), '50');
    await toggle(tester, 'settings-verify-ssl');
    await toggle(tester, 'settings-confirm-discard');
    await toggle(tester, 'settings-no-cache');
    await toggle(tester, 'settings-follow-redirects');
    await pick(tester, 'settings-layout', 'Stacked');
    await tester.enterText(find.byKey(const Key('settings-font-size')), '16');
    await pick(tester, 'settings-indent', 'Tab');
    await tester.pumpAndSettle();

    final s = store.settings;
    expect(
      (s.httpMode, s.timeoutSecs, s.maxResponseMb),
      (HttpMode.http1, 30, 50),
    );
    expect(
      (s.verifySsl, s.confirmDiscard, s.sendNoCache, s.followRedirects),
      (false, false, true, false),
    );
    expect((s.layout, s.fontSize, s.indent), (Layout.stacked, 16, Indent.tab));
    expect(find.text('A response over 50 MB is abandoned.'), findsOneWidget);

    // The code style follows, and the workspace is written through.
    expect((CodeStyle.fontSize, CodeStyle.indent), (16.0, '\t'));
    await tester.pump(const Duration(seconds: 1));
    expect(engine.saved!.settings.maxResponseMb, 50);

    await tester.tap(find.byKey(const Key('settings-editor-reset')));
    await tester.pumpAndSettle();
    expect(
      (store.settings.fontSize, store.settings.indent),
      (13, Indent.twoSpaces),
    );
    expect(CodeStyle.fontSize, 13.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the font size stays within a readable range', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('settings-font-size')), '99');
    await tester.pumpAndSettle();
    expect(store.settings.fontSize, 28);
    await tester.enterText(find.byKey(const Key('settings-font-size')), '1');
    await tester.pumpAndSettle();
    expect(store.settings.fontSize, 9);
  });

  testWidgets('chooses a proxy', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('settings-proxy')));
    await tester.pumpAndSettle();
    TextField address() =>
        tester.widget<TextField>(find.byKey(const Key('settings-proxy-url')));
    expect(address().enabled, isFalse);

    await tester.tap(find.text('Through this proxy'));
    await tester.pumpAndSettle();
    expect(address().enabled, isTrue);
    expect(find.textContaining('until then the system proxy'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('settings-proxy-url')),
      ' http://127.0.0.1:8080 ',
    );
    await tester.pumpAndSettle();
    expect(
      (store.settings.proxy, store.settings.proxyUrl),
      (ProxyMode.custom, 'http://127.0.0.1:8080'),
    );

    await tester.tap(find.text('Directly'));
    await tester.pumpAndSettle();
    expect(store.settings.proxy, ProxyMode.none);
    // The address is kept for next time.
    expect(store.settings.proxyUrl, 'http://127.0.0.1:8080');
  });

  testWidgets('lists the shortcuts and says where the workspace is', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('settings-shortcuts')));
    await tester.pumpAndSettle();
    expect(find.text('Save the request'), findsOneWidget);
    expect(find.text('Show or hide the sidebar'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-about')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Version '), findsOneWidget);
    expect(find.text('/tmp/workspace.json'), findsOneWidget);
  });

  testWidgets('requests are sent with the settings chosen', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('settings-max-size')), '5');
    await toggle(tester, 'settings-follow-redirects');
    await tester.tap(find.byKey(const Key('settings-close')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('url')), 'https://api.test');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
    final sent = engine.sentSettings.single;
    expect((sent.maxResponseMb, sent.followRedirects), (5, false));

    // A request's own Settings tab starts from the app's choices.
    // The request's tabs scroll sideways in a narrow pane.
    await tester.ensureVisible(find.byKey(const Key('request-settings-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('request-settings-tab')));
    await tester.pumpAndSettle();
    final follow = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const Key('rs-follow-redirects')),
        matching: find.byType(Switch),
        matchRoot: true,
      ),
    );
    expect(follow.value, isFalse);
  });

  testWidgets('unsaved edits are dropped without asking when told to', (
    tester,
  ) async {
    await open(tester);
    await toggle(tester, 'settings-confirm-discard');
    await tester.tap(find.byKey(const Key('settings-close')));
    await tester.pumpAndSettle();

    store.addStandaloneRequest(
      'Ping',
      const Request(
        method: 'GET',
        url: 'https://api.test/ping',
        headers: [],
        form: [],
        tests: [],
        captures: [],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ping'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('url')), 'https://changed');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unsaved')), findsOneWidget);

    await tester.tap(find.byKey(const Key('new-request')));
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsNothing);
    expect(find.text('Untitled request'), findsOneWidget);
  });

  testWidgets('the layout setting decides where the response goes', (
    tester,
  ) async {
    await open(tester);
    expect(responseAxis(Layout.auto, 1200), Axis.horizontal);
    expect(responseAxis(Layout.auto, 600), Axis.vertical);
    expect(responseAxis(Layout.stacked, 1200), Axis.vertical);
    expect(responseAxis(Layout.sideBySide, 600), Axis.horizontal);
  });
}
