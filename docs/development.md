# Development

## Requirements

| Tool | Version | Needed for |
|---|---|---|
| Rust | 1.99 or later (stable) | Everything |
| Flutter | 3.47 or later (stable) | The app |
| Xcode | 26 or later | The macOS and iPad builds. Older versions build, but without the dark and tinted app icons |
| `flutter_rust_bridge_codegen` | 2.13.0, matching `app/pubspec.yaml` | Only when you change `app/rust/src/api` |
| `cargo-llvm-cov` | any | Only for `scripts/coverage.sh` |

The app has been built and tested on macOS and the iPad simulator. Windows and Linux are
targets, and CI tests the Rust code on both, but the app has not been built on either yet.

## Getting the code running

```bash
git clone https://github.com/nevin/reqorb.git
cd reqorb
cargo build --workspace
cd app && flutter pub get
```

You do not build the Rust library for the app yourself: `app/rust_builder` is a Flutter
plugin (cargokit) that compiles `app/rust` as part of every `flutter run` and
`flutter build`, for whichever platform and architecture is being built.

### The app

```bash
cd app && flutter run -d macos
cd app && flutter run -d "iPad Pro 11-inch (M4)"   # any booted simulator; see `flutter devices`
```

Hot reload works for Dart. **Changes to Rust need a full restart** (`R` in `flutter run`,
or stop and run again): the native library is built and loaded once.

The macOS app is sandboxed, so its files are inside its container:
`~/Library/Containers/dev.reqorb.reqorb/Data/Library/Application Support/dev.reqorb.reqorb/`.
Delete `workspace.json` there to start from an empty workspace. Credentials in it are
encrypted with a key kept in the login keychain (service `reqorb`, account
`workspace-key`).

### The CLI

```bash
cargo run -p reqorb-cli -- GET httpbin.org/get -i
cargo run -p reqorb-cli -- --help
cargo install --path crates/reqorb-cli     # installs `reqorb` into ~/.cargo/bin
```

The CLI is the quickest way to try a change to the core: it reaches most of the engine
without building the app.

## Changing the bridge

The Dart bindings in `app/lib/src/rust/` and `app/rust/src/frb_generated.rs` are
generated from `app/rust/src/api/core.rs`. They are committed, so most changes never need
the generator. Run it after you add, remove or change anything public in `api/`,
including a mirrored type whose core type gained a field:

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked   # once
cd app && flutter_rust_bridge_codegen generate
```

Commit the regenerated files with the change that needed them. Never edit them by hand;
the next generation overwrites them. [Extending reqorb](extending.md#a-new-bridge-call)
walks through adding a function end to end.

## Day-to-day commands

```bash
cargo test -p reqorb-core formats::          # one module's tests
cargo test -p reqorb-core big_yaml           # tests whose names contain this
cargo test -p reqorb-cli                     # the CLI against a local server
cd app && flutter test test/spec_test.dart   # one test file
cd app && flutter test --name "pretty"       # tests whose names contain this
```

The full set to run before pushing is in [CONTRIBUTING.md](../CONTRIBUTING.md#before-you-push).

## Debugging

- **Rust in isolation.** Most bugs reproduce in a core test: build the request, call the
  function, assert on the result. Tests that need a server start one on `127.0.0.1:0`;
  copy `serve_once` or `serve` from `crates/reqorb-core/src/http/tests.rs`.
- **Rust behind the app.** An error from the core reaches the app as the string of its
  `Error`, shown where the action was taken. To see more, reproduce it through the CLI or
  a core test, where a temporary `eprintln!` prints to the terminal. `dbg!` is denied by
  the workspace lints, so it cannot be committed by accident.
- **Dart.** `flutter run` opens DevTools for the widget tree, performance and memory.
  For layout and performance work, `flutter run --profile` gives realistic timings;
  debug builds can be several times slower.
- **Scripts.** `console.log` in a pre-request or post-response script shows in the
  response's **Console** section in the app, and after the response in the CLI.
- **Performance of large inputs.** Long work runs off the UI thread: Rust calls are
  asynchronous, and Dart work over a size threshold uses `Isolate.run` (see
  `readSpecApart` in `app/lib/spec/api_spec.dart` and `_asJsonApart` in
  `app/lib/response/response_view.dart`). Text over a megabyte is shown in `LineView`
  rather than the editor, which lays out all its text on every change.
- **iPad.** The iPad simulator shares the Mac's network, so a server on the Mac is
  reachable at `localhost`. `xcrun simctl ui booted appearance dark` switches the
  simulator to dark mode without touching the Mac.

When something goes wrong that this page does not explain, see
[Troubleshooting](troubleshooting.md).

## Formatting and lints

- Rust: `cargo fmt`, and `cargo clippy` with warnings as errors.
- Dart: `dart format`, and the lints in `app/analysis_options.yaml`.

Neither is negotiable in CI, so format before committing.
