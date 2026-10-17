# Architecture

reqorb is one engine with two front ends. Everything that touches the network, a file
format or the disk is Rust, in `reqorb-core`. The CLI calls it directly; the Flutter app
calls it through a generated bridge. Neither front end sends a request or parses a file
by itself.

```text
            ┌────────────────────┐      ┌───────────────────────────────┐
            │  reqorb-cli        │      │  app/ (Flutter)               │
            │  crates/reqorb-cli │      │  widgets ─ models ─ Engine    │
            └─────────┬──────────┘      └──────────────┬────────────────┘
                      │                                │ flutter_rust_bridge
                      │                 ┌──────────────▼────────────────┐
                      │                 │  app/rust (rust_lib_reqorb)   │
                      │                 │  src/api/core.rs              │
                      │                 └──────────────┬────────────────┘
            ┌─────────▼────────────────────────────────▼────────────────┐
            │  reqorb-core: model, http/ws/grpc, auth, formats, codegen, │
            │  scripts, vars, checks, vault, history                     │
            └────────────────────────────────────────────────────────────┘
                 reqorb-alloc: the allocator both programs install
```

## The crates

| Crate | Path | What it is |
|---|---|---|
| `reqorb-core` | `crates/reqorb-core` | The engine: data model, protocols, formats, scripts, storage |
| `reqorb-cli` | `crates/reqorb-cli` | The `reqorb` command, a thin layer of argument parsing and printing |
| `reqorb-alloc` | `crates/reqorb-alloc` | The global allocator, which counts what a script allocates so it can be held to a limit |
| `rust_lib_reqorb` | `app/rust` | The bridge crate: the functions and types the app can reach, nothing else |

Dependencies point one way. The CLI and the bridge depend on the core, never the reverse.
Inside the core, `model` depends on nothing, and the protocol and format modules depend
on `model`. `lib.rs` holds only the module list and the public re-exports: if something
is not re-exported there, nothing outside the core can use it.

The workspace forbids `unsafe` code and denies `dbg!`, `todo!` and `unimplemented!`
(see `Cargo.toml`).

## Inside the core

| Module | Responsibility |
|---|---|
| `model` | Requests, collections, environments, settings, the workspace. Plain data with serde, no behaviour that needs the network |
| `error` | The one `Error` type. Its `Display` text is shown to users as it is |
| `http/` | Sending: the client cache (`client.rs`), one exchange (`exchange.rs`), the cookie jar, and watching or cancelling a send under way (`watch.rs`) |
| `ws`, `grpc` | The other two protocols |
| `graphql`, `subscribe` | GraphQL over HTTP, and subscriptions over a WebSocket |
| `auth/` | Auth types and their fields (`mod.rs`), signing a request (`sign.rs`), and those that need the server first: Digest and NTLM challenges, OAuth 2 tokens (`negotiate.rs`) |
| `vars` | `{{variable}}` substitution, and reporting the ones left unresolved |
| `checks` | Tests on a response, and captures that turn parts of it into variables |
| `script` | Pre-request and post-response JavaScript, run on [Boa](https://boajs.dev) in a thread of its own with time and memory limits; `script_prelude.js` is the API scripts see |
| `formats/` | Import and export, one module per format holding both directions; `mod.rs` detects what a piece of text is |
| `codegen/` | A request written out as code in one of 16 languages |
| `redact`, `analyze`, `data` | Removing credentials from exports; the HAR report; the data file of a collection run |
| `vault`, `history` | What is kept on disk: the workspace with its credentials encrypted, and the requests sent |
| `files` | Checking that a working directory can be read and written |
| `document/` | Text of any size, up to about a gigabyte, for the editor. The original bytes are read from memory or a file a page at a time (`source.rs`); a background thread counts newlines every 4 KB (`index.rs`); edits are a piece table over the original and an append-only buffer, so undo copies no text (`text.rs`); search runs over a snapshot a megabyte at a time (`search.rs`). Lines over 2 KB are shown over several rows, and columns are counted in UTF-16 units, as Dart counts them |

## The CLI

`crates/reqorb-cli` is a thin layer over the core, and should stay one: logic that the
app could also use belongs in the core.

| File | Holds |
|---|---|
| `src/cli.rs` | Every command, argument and option, declared with clap |
| `src/input.rs` | Reading what the user gave: files, headers, variables, credentials |
| `src/output.rs` | Printing responses, tests and console output, and writing files |
| `src/commands/` | One module per command: `send`, `run`, `convert` (import and export), `code`, `ws`, `grpc`, `analyze` |

## Following a request

Here is what happens when someone presses **Send** in the app. The CLI's `send` command
takes the same path from `reqorb_core::send_with` down.

1. **The page asks its session.** `RequestPage` hands the current `RequestDraft` to its
   `SendSession` (`app/lib/request/send_session.dart`), which marks itself as sending and
   notifies, so the button turns into **Cancel**.
2. **Variables are gathered in Dart.** `WorkspaceStore.variablesFor` builds the list,
   highest priority first: values captured this session, then the active environment, then
   the request's collection.
3. **The engine is called.** `SendSession` calls `Engine.sendWatched`, and `RustEngine`
   forwards it to the generated binding for `send_request_watched` in
   `app/rust/src/api/core.rs`. Each send has an id, which `cancelSend` uses.
4. **The core runs the pipeline.** `http::send_watched` in `reqorb-core`:
   - runs the pre-request script, if there is one, in a thread of its own;
   - resolves `{{variables}}` with `vars::resolve`;
   - signs the request for its auth type, or negotiates with the server for those that
     need a round trip;
   - sends it with a cached `reqwest` client chosen by its TLS, proxy and HTTP-version
     settings, following redirects and recording every exchange;
   - reads the body in pieces, reporting the head and then the body as it arrives, and
     stops at the size limit in Settings;
   - runs the request's tests and captures, then the post-response script.
5. **Updates stream back.** Each `SendUpdate` crosses the bridge on a Dart stream: the
   head, pieces of body, and finally the whole `Sent` result or an error message.
6. **The UI follows the model.** `SendSession` stores what has arrived and notifies;
   `ResponseView` rebuilds from it. Captured variables go into the store for the next send,
   and the exchange is appended to history.

## The app

The app follows one rule: **widgets show state and hand actions on; models own the
state.** Models are `ChangeNotifier`s:

| Model | Owns |
|---|---|
| `WorkspaceStore` (`app/lib/workspace/`) | Collections, environments, settings, cookies and history. It loads them at start-up and saves 300 ms after the last change |
| `RequestDraft` (`app/lib/request/`) | The request being edited in a tab, with undo |
| `SendSession` | One tab's send: under way, received, cancelled |
| `WsSession`, `GrpcSession`, `GraphqlSession` | A WebSocket, a gRPC call, a GraphQL schema |

Widgets listen with `ListenableBuilder` and call methods on models; they do not reach
past them to the engine.

**Everything that reaches Rust goes through `Engine`** (`app/lib/bridge/engine.dart`).
It is an abstract class with two implementations: `RustEngine`, which calls the generated
bindings, and `FakeEngine` in `app/test/fake_engine.dart`. Widgets find it with
`Engine.of(context)`, provided by the `EngineScope` that `main.dart` puts at the root. That
seam is what lets `flutter test` run the whole app without the native library; see
[Testing](testing.md).

Start-up (`app/lib/main.dart`) initialises the bridge (`RustLib.init()`), loads
`workspace.json` from the platform's application support directory, then loads history,
the working directory and linked collection folders in parallel, and runs the app.

The `app/lib/` folders are features:

| Folder | Holds |
|---|---|
| `bridge/` | `Engine`, the only interface to Rust |
| `request/` | The main page, the request model, the send session, the request editors and the code dialog |
| `response/` | The response pane, server-sent events |
| `protocols/` | WebSocket and gRPC sessions and views |
| `editor/` | The code editor: colouring, typing aids, find and replace, folding, completion, and the read-only `LineView` for text over a megabyte |
| `graphql/` | The GraphQL editor, schema browser and schema session |
| `spec/` | The API spec viewer: preview, problems, examples, Try it |
| `runner/`, `palette/` | Running a collection; the find-anything box |
| `sidebar/`, `environments/`, `settings/`, `har/`, `history/` | What their names say |
| `transfer/` | Import and export actions |
| `workspace/` | The store and the collection actions |
| `shared/` | Theme, messages, folders and small reusable widgets |
| `src/rust/` | The generated bindings; never edited by hand |

## The bridge

[flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/) 2.13 generates the Dart
side from `app/rust/src/api/core.rs`, as configured in `app/flutter_rust_bridge.yaml`.
The conventions in that file:

- **Core types are mirrored, not copied.** A `#[frb(mirror(Request))] pub struct _Request`
  describes the core's `Request` field for field, so the bridge generates a matching Dart
  class while the Rust code keeps using the core type. A mirror must list every field the
  core type has; when you change a core type that crosses the bridge, change its mirror
  too, or the generated code will not compile.
- **Errors cross as strings** ready to show to the user: functions return
  `Result<T, String>`, mapping the core error with `to_string()`.
- **Quick functions are synchronous.** Those that only compute, such as
  `default_settings` or `generate_code`, are `#[frb(sync)]` and return straight away in
  Dart; anything that waits on the network or the disk is `async`.
- **Long-running work streams.** Watched sends, WebSockets and gRPC calls take a
  `StreamSink` and report events as they happen, under an id the app uses to cancel them.
- **Panics do not crash the app.** Release builds keep unwinding (`Cargo.toml`), and the
  bridge turns a panic into an error for the call that caused it.

## What is kept on disk

| File | Written by | Holds |
|---|---|---|
| `workspace.json` | `vault::save_workspace` | Collections, environments, settings, cookies. Readable JSON, with every credential encrypted with XChaCha20-Poly1305 under a key kept in the system keychain |
| History | `history::append_history` | The requests sent, most recent last, trimmed to the limit in Settings |
| A collection folder | `formats::write_collection_dir` | A collection kept as one file per request, for version control |

Files are written whole or not at all, and readable only by their owner. [SECURITY.md](../SECURITY.md)
explains what is protected and how.
