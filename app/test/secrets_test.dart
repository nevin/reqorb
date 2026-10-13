import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/environments/environments.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  test('a variable is marked as a credential by the word secret', () {
    const text =
        'base=https://api.test\nsecret session=abc=123\n# secret old=x';
    final variables = textToVariables(text);
    expect(
      [for (final v in variables) (v.key, v.value, v.enabled, v.secret)],
      [
        ('base', 'https://api.test', true, false),
        ('session', 'abc=123', true, true),
        ('old', 'x', false, true),
      ],
    );
    expect(variablesToText(variables), text);
    // A name that merely starts with the word is just a name.
    expect(textToVariables('secretive=1').single.key, 'secretive');
    expect(textToVariables('secretive=1').single.secret, isFalse);
  });

  group('store', () {
    test(
      'reports credentials left unencrypted, and when that is put right',
      () async {
        final engine = FakeEngine()..keychainFailure = 'the keychain is locked';
        final store = WorkspaceStore('unused.json', engine: engine);
        var changes = 0;
        store.addListener(() => changes++);

        store.addEnvironment();
        await store.flush();
        expect(store.unprotected, 'the keychain is locked');
        final afterFailure = changes;

        // Saved again with nothing new to say, nobody is told again.
        store.addEnvironment();
        await store.flush();
        expect(changes, afterFailure + 1);

        // Not asked for, encryption cannot fail.
        store.updateSettings(store.settings.copyWith(protectSecrets: false));
        await store.flush();
        expect(store.unprotected, isNull);

        engine.keychainFailure = null;
        store.updateSettings(store.settings.copyWith(protectSecrets: true));
        await store.flush();
        expect(store.unprotected, isNull);
        expect(engine.saved!.settings.protectSecrets, isTrue);
      },
    );

    test('counts locked credentials, and again as they are replaced', () async {
      final engine = FakeEngine();
      final first = WorkspaceStore('unused.json', engine: engine);
      first.addEnvironment();
      await first.flush();

      engine.locked = 2;
      final store = WorkspaceStore('unused.json', engine: engine);
      await store.load();
      expect(store.lockedSecrets, 2);
      expect(store.keyProblem, 'its key is not in this keychain');

      engine.locked = 1;
      store.addEnvironment();
      await store.flush();
      expect(store.lockedSecrets, 1);
      engine.locked = 0;
      store.addEnvironment();
      await store.flush();
      expect(store.lockedSecrets, 0);
    });
  });

  group('settings', () {
    late FakeEngine engine;
    late WorkspaceStore store;

    Future<void> open(WidgetTester tester, {int locked = 0}) async {
      engine = FakeEngine();
      store = WorkspaceStore('unused.json', engine: engine);
      if (locked > 0) {
        engine
          ..saved = Workspace(
            collections: const [],
            requests: const [],
            environments: const [],
            settings: engine.defaultSettings(),
            cookies: const [],
          )
          ..locked = locked;
        await store.load();
      }
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ReqorbApp(store: store));
      addTearDown(() => tester.pump(const Duration(seconds: 1)));
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
    }

    Future<void> toggle(WidgetTester tester) async {
      final control = find.byKey(const Key('settings-protect-secrets'));
      await tester.ensureVisible(control);
      await tester.tap(control);
      // Long enough for the change to be saved, and the outcome shown.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    testWidgets('credentials are encrypted unless switched off', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Security'), findsOneWidget);
      expect(store.settings.protectSecrets, isTrue);
      expect(
        find.textContaining('kept in the system keychain'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-secrets-unprotected')),
        findsNothing,
      );
      expect(find.byKey(const Key('settings-secrets-locked')), findsNothing);

      await toggle(tester);
      expect(store.settings.protectSecrets, isFalse);
      expect(engine.saved!.settings.protectSecrets, isFalse);
      expect(find.textContaining('as plain text'), findsOneWidget);
    });

    testWidgets('says when the keychain cannot be used', (tester) async {
      await open(tester);
      engine.keychainFailure = 'the keychain is locked';
      await toggle(tester);
      await toggle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('settings-secrets-unprotected')))
            .data,
        'Not encrypted: the keychain is locked. Credentials are being saved '
        'as plain text.',
      );
    });

    testWidgets('says how many credentials could not be unlocked', (
      tester,
    ) async {
      await open(tester, locked: 3);
      final text = tester
          .widget<Text>(find.byKey(const Key('settings-secrets-locked')))
          .data!;
      expect(
        text,
        startsWith(
          '3 saved credentials are locked: its key is not in this keychain.',
        ),
      );
      expect(text, contains('Nothing is lost'));
    });
  });
}
