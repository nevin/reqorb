import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/src/rust/api/core.dart';
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

  test('saves run one after another, the latest written last', () async {
    final engine = _SlowEngine();
    final store = WorkspaceStore('unused.json', engine: engine);

    store.addEnvironment();
    final first = store.flush();
    await pumpEventQueue();
    expect(engine.writing, 1);

    // Changed again while the first save is still being written.
    store.addEnvironment();
    final second = store.flush();
    await pumpEventQueue();
    expect(engine.writing, 1, reason: 'the second waits for the first');

    engine.finish();
    await pumpEventQueue();
    engine.finish();
    await Future.wait([first, second]);
    expect(engine.most, 1);
    expect(engine.saved!.environments, hasLength(2));
  });
}

/// Writes a workspace only when told to, so that saves can overlap.
class _SlowEngine extends FakeEngine {
  final _waiting = <Completer<void>>[];
  int writing = 0;
  int most = 0;

  void finish() => _waiting.removeAt(0).complete();

  @override
  Future<String?> saveWorkspace({
    required String path,
    required Workspace workspace,
  }) async {
    writing++;
    if (writing > most) most = writing;
    final done = Completer<void>();
    _waiting.add(done);
    await done.future;
    saved = workspace;
    writing--;
    return null;
  }
}
