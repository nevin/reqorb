import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/workspace/workspace_store.dart';

import 'fake_engine.dart';

void main() {
  group('a change is not lost', () {
    late FakeEngine engine;
    late WorkspaceStore store;

    setUp(() {
      engine = FakeEngine();
      store = WorkspaceStore('unused.json', engine: engine);
    });

    testWidgets('when the app loses focus', (tester) async {
      final listener = store.saveWhenLeaving();
      addTearDown(listener.dispose);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      store.addEnvironment();
      expect(engine.saved, isNull, reason: 'the timer has not fired');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(engine.saved!.environments, hasLength(1));
    });

    testWidgets('when the app is asked to quit', (tester) async {
      final listener = store.saveWhenLeaving();
      addTearDown(listener.dispose);

      store.addEnvironment();
      final response = await tester.binding.handleRequestAppExit();
      expect(response, AppExitResponse.exit);
      expect(engine.saved!.environments, hasLength(1));
    });

    testWidgets('when the store is disposed', (tester) async {
      store.addEnvironment();
      store.dispose();
      await tester.pump();
      expect(engine.saved!.environments, hasLength(1));
    });
  });
}
