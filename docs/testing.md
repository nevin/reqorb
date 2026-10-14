# Testing

There are four layers of tests. Each catches a different kind of mistake, and a change
usually needs only one or two of them.

| Layer | Where | Runs | Speed |
|---|---|---|---|
| Core tests | `crates/reqorb-core/src/**/tests.rs` and `*_tests.rs` | `cargo test -p reqorb-core` | Seconds |
| CLI tests | `crates/reqorb-cli/tests/cli.rs` | `cargo test -p reqorb-cli` | Seconds |
| App tests | `app/test/` | `cd app && flutter test` | About 30 seconds |
| End-to-end | `app/integration_test/` | `cd app && flutter test integration_test -d macos` | Minutes; takes over the screen |

`cargo test --workspace` runs the first two. CI runs all four on every push, and any
failure fails the run.

**No test reaches the internet.** Tests that need a server start one on a free port on
`127.0.0.1` and talk to that, so they pass offline and are not flaky.

## Which test to write

- **The change is in the core** (a format, a protocol, auth, variables, scripts): write a
  core test. This is where most tests belong, and where they are cheapest.
- **The change is a CLI option or its output:** add a case to `crates/reqorb-cli/tests/cli.rs`.
- **The change is in the app** (a widget, a model, a flow between screens): write an app
  test against `FakeEngine`.
- **The change is in how the app and the engine meet** (the bridge, a new `Engine`
  method, storage): extend an end-to-end test.

A bug fix starts with a test that fails because of the bug.

## Core tests

Each module keeps its tests next to it: in a `tests.rs` for a module that is a folder
(`http/tests.rs`, `auth/tests.rs`, `codegen/tests.rs`), in `import_tests.rs` and
`export_tests.rs` for `formats`, and otherwise in a `#[cfg(test)] mod tests` at the
bottom of the file (`grpc.rs`, `vault.rs`). They are ordinary `#[test]` and `#[tokio::test]` functions with access
to the module's private items.

For anything on the network, `http/tests.rs` has two small servers to copy:

- `serve_once(response)` answers one connection with a fixed response and hands back the
  request it received, for asserting on what was sent.
- `serve(responses)` answers several requests in order, for redirects and auth round
  trips.

Tests run under the same counting allocator as the programs (`reqorb-alloc`), so a test
that runs a script is held to the same memory limit a user's script is.

Inputs that could hang or exhaust memory, such as an alias bomb in YAML or a script that
loops forever, are tested to fail quickly: assert on the error *and* on the time it took.
See `yaml_openapi_with_number_keys_aliases_and_a_bomb` in `formats/import_tests.rs`.

## CLI tests

`crates/reqorb-cli/tests/cli.rs` builds the real `reqorb` binary, starts a small API with
`serve()` (`/login`, `/me`, `/graphql`, `/logo.png`, documented at the top of the file),
runs the binary against it, and checks what it prints and its exit code. Add a route to
`serve()` when a test needs a new kind of answer.

## App tests

`flutter test` runs the whole app, headlessly, without the Rust library. The seam is
`Engine`: tests give `WorkspaceStore` a `FakeEngine` (`app/test/fake_engine.dart`), which
records what it is asked and answers what the test set up.

The usual shape:

```dart
testWidgets('a sent request shows its response', (tester) async {
  final engine = FakeEngine();
  final store = WorkspaceStore('unused.json', engine: engine);
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ReqorbApp(store: store));

  engine.onSend = (_) async => sentWith(response(body: '{"id":7}'));
  // ...enter a URL, tap Send...
  await tester.pumpAndSettle();

  expect(engine.sends.single.$1.url, 'https://api.test/items');
  expect(find.textContaining('"id": 7'), findsOneWidget);
});
```

- **Find widgets by key.** Interactive widgets carry a `Key` (`Key('send')`,
  `Key('spec-try-GET /pets')`); find them with `find.byKey` rather than by text, so a
  wording change does not break tests. Give anything new that a test drives a key.
- **Set the window size** with `tester.view.physicalSize` when layout matters; wide and
  narrow layouts differ.
- **Change what the engine answers** by replacing a handler such as `onSend`, or, for
  behaviour across several calls, by subclassing `FakeEngine` (see `_RunEngine` in
  `runner_test.dart`).
- **Background work needs real time.** Widget tests run in a fake clock, so work handed to
  `Isolate.run` never finishes on its own. Wait for it inside `tester.runAsync`, then
  pump:

  ```dart
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  ```

  `spec_test.dart` and `response_view_test.dart` do this for large inputs.
- **Pure logic** (parsing, formatting, models) does not need a widget: test it with plain
  `test()`, as `logic_test.dart` and `request_draft_test.dart` do.

When you add a method to `Engine`, `FakeEngine` must implement it too, or the tests do not
compile.

## End-to-end tests

`app/integration_test/send_request_test.dart` runs the real app, with the real Rust
library, against an `HttpServer` it starts on the loopback address, using a workspace in a
temporary folder. It covers what the fake cannot: that the bridge carries every field
both ways, that saving and loading round-trips, that importing real files works.

These tests drive the real window. They stall if the display sleeps and taps go astray if
another window takes focus, so run them with `caffeinate -d` and leave the machine alone:

```bash
cd app && caffeinate -d flutter test integration_test -d macos
```

CI runs them on a clean runner on every push. Locally, prefer `flutter test`; run the
end-to-end tests when you change the bridge, storage or anything the fake stands in for.

## Coverage

```bash
scripts/coverage.sh
```

This measures line coverage of the Rust crates by their tests and of the app by
`flutter test`, and fails if either falls below its floor: 90% for Rust and 80% for the
app (`RUST_COVERAGE_FLOOR` and `DART_COVERAGE_FLOOR` override them). The bridge crate and
the generated bindings are left out; the end-to-end tests exercise them. Raise the floors
as coverage grows. It needs `cargo-llvm-cov`.

## Checking by hand

Some things tests cannot judge: whether a layout looks right, whether scrolling is smooth,
how an icon renders. For those, run the app on macOS and on the iPad simulator, and
describe what you checked when you open the pull request.
