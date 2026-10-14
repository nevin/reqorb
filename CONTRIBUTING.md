# Contributing to reqorb

reqorb is a request engine written in Rust, with two front ends over it: the `reqorb`
command and a Flutter app for macOS, iPad, Windows and Linux. This page gets you from a
fresh clone to a change that is ready to push. The guides in [docs/](docs/) go deeper.

| Guide | Read it to |
|---|---|
| [Architecture](docs/architecture.md) | see how the crates and the app fit together, and follow a request from a click to the network and back |
| [Development](docs/development.md) | set up a machine, run the app and the CLI, change the Rust–Dart bridge, and debug |
| [Testing](docs/testing.md) | know which tests to write and run, and how the app is tested without its Rust library |
| [Extending reqorb](docs/extending.md) | add an import or export format, a code language, an auth type, a setting or a bridge call |
| [Releasing](docs/releasing.md) | cut a version, sign the macOS app, and change the app icon |
| [File formats](docs/file-formats.md) | read or generate reqorb files and collection folders |
| [Script reference](docs/scripts.md) | see everything a pre-request or post-response script can use |
| [Troubleshooting](docs/troubleshooting.md) | get past a failed build, a stalled test or locked credentials |

## Set up

You need Rust 1.99 or later, Flutter 3.47 or later, and Xcode for the macOS and iPad
builds. Then:

```bash
cargo build --workspace
cd app && flutter pub get && flutter run -d macos
```

[Development](docs/development.md) has the details, including the iPad simulator and the
tools needed only for some changes.

## Before you push

Run the same checks as CI. Each must pass:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd app && dart format --output=none --set-exit-if-changed lib test integration_test
cd app && flutter analyze
cd app && flutter test
```

`flutter test` runs the whole app headlessly in about half a minute, so run it often. The
end-to-end tests (`flutter test integration_test -d macos`) take over the screen; see
[Testing](docs/testing.md) for when they are worth running yourself.

## How changes are written

- **Code reads like the code around it.** Match the naming, comment density and idiom of
  the file you are in. Comments say why, in plain sentences; doc comments describe what a
  thing is for, not how it works line by line.
- **A behaviour change comes with a test** that fails without it. A bug fix starts with
  the failing test.
- **Errors are for people.** Messages that reach the user say what went wrong and what to
  do, in words a user would use: "the response is larger than the limit of 5 MB set in
  Settings", not "body limit exceeded".
- **Dependencies are added sparingly.** Raise a new crate or package before adding it,
  and say why existing code cannot do the job.
- **The repository stays lean.** No generated files beyond the bridge bindings, no
  editor settings, no tooling configuration that the build does not need.
- **User-visible changes go in the changelog**, under **Unreleased** in
  [CHANGELOG.md](CHANGELOG.md).
- **Commits** are small and self-contained, with a subject line in the imperative ("Show
  big responses without freezing") and a body that explains why.

## Reporting a security problem

Do not open a public issue. See [SECURITY.md](SECURITY.md).
