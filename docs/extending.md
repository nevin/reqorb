# Extending reqorb

Recipes for the changes that come up most. Each lists every place that needs touching,
in the order to do it, so nothing is left half-wired. Read [Architecture](architecture.md)
first if you have not.

Most of these end at the bridge. When they do, regenerate it
(`cd app && flutter_rust_bridge_codegen generate`, see [Development](development.md#changing-the-bridge))
and commit the generated files with the change.

## A new import format

Import starts at `formats::import` in `crates/reqorb-core/src/formats/mod.rs`, which
works out what a piece of text is and hands it to the matching format.

1. **Add a module** `formats/<format>.rs` with a function that turns the text, or the
   parsed `serde_json::Value`, into collections and environments. Keep both directions of
   a format in its one module, so add export here later too.
2. **Detect it** in `parse` in `formats/mod.rs`. The order of the checks matters: JSON is
   tried as OpenAPI, then a reqorb file, a Postman collection, a Postman environment, a
   HAR archive; then YAML OpenAPI, a curl command, and `.env` lines. Put the new check
   where it cannot be mistaken for another format, and make it as specific as it can be.
   A JSON format also goes in the error listing what JSON can be, at the end of the JSON
   branch.
3. **Return an `ImportResult`** with `source` set to the format's name and a `warning` for
   everything that could not be carried over. Say what was lost and why, in words a user
   would understand. Do not drop things silently.
4. **Leave scripts and files for review.** `import_from` marks a collection with scripts
   or file references as `unreviewed`, so the app asks before they run. If the format has
   scripts, carry them into `pre_script` and `post_script` and that protection applies.
5. **Test it** in `formats/import_tests.rs`: a small real-world sample, what it becomes,
   the warnings, and that malformed input gives an error rather than a panic. Large inputs
   should import in reasonable time; see `big_yaml_openapi_comes_in`.

The CLI (`reqorb import`) and the app (Import file, Import from URL, Paste) use
`formats::import`, so both pick up the format with no further change. Add it to the
**Import** helper text in `app/lib/transfer/import_actions.dart` and to the README.

## A new export format

1. **Add a variant** to `ExportFormat` in `formats/mod.rs`, and handle it in
   `export_collection` and `export_environment`. A format that cannot hold one of them
   returns an `Error::Format` saying so, as `.env` does for collections.
2. **Mirror it** in the `_ExportFormat` enum in `app/rust/src/api/core.rs`, and
   regenerate the bridge.
3. **In the CLI**, add the variant to `Format` in `crates/reqorb-cli/src/cli.rs` and to
   its `From<Format> for ExportFormat`.
4. **In the app**, offer it in `app/lib/transfer/export_actions.dart`, with its file
   suffix.
5. **Test it** in `formats/export_tests.rs`. If the format can also be imported, test the
   round trip: export, import, compare.

Exports pass through `redact` when the user asks for credentials to be removed, so a new
format must not write credentials anywhere `redact_collection` does not reach.

## A new code language

Code generation lives in `crates/reqorb-core/src/codegen/`. Every language is handed the
request already resolved: variables filled in, auth turned into headers, form fields and
GraphQL turned into the body. Each language only spells that in its own HTTP client.

1. **Add a variant** to `CodeTarget` in `codegen/mod.rs`, and add it to `ALL` (the order
   pickers list it in), `id` (its name on the command line), `label`, `extension`, and,
   for any usual short forms, `from_id`.
2. **Write the generator** in the module for its family (`scripts.rs`, `compiled.rs`,
   `jvm.rs`, `dotnet.rs`, `javascript.rs`, `swift.rs`), or a new module if none fits, and
   call it from the `match` in `generate_code`. Use `text.rs` for quoting and escaping
   rather than writing it again.
3. **Mirror nothing.** `CodeTarget` crosses the bridge already, and `code_choices()`
   lists `ALL`, so the app's code dialog and `reqorb code` both offer the language. Do
   regenerate the bridge, since the enum gained a variant.
4. **Test it** in `codegen/tests.rs`: a GET, a JSON POST, a form, headers that need
   escaping. Check the output compiles or runs where you can.

## A new auth type

Auth is in `crates/reqorb-core/src/auth/`.

1. **Add a variant** to `AuthKind` in `auth/mod.rs`, with a `#[serde(rename)]` id. Use
   Postman's name for it where Postman has one: Postman import and export map auth by
   that id, so the type then carries over both ways with no extra code. Add it to `ALL`
   and `label`.
2. **Describe its inputs** in `auth_fields`: `text`, `secret` and `choice` fields, in the
   order the form shows them. Mark every credential as `secret`, so it is encrypted on
   disk and redacted on export.
3. **Apply it.** A type that only changes the request (a header, a query parameter, a
   signature) goes in `sign` in `auth/sign.rs`. One that needs the server first, such as
   a challenge or a token fetch, goes in `auth/negotiate.rs`.
4. **Write it out.** Update `to_curl` in `formats/curl.rs`, and `prepare` in
   `codegen/mod.rs` if it can be expressed as headers.
5. **Mirror it** in the `_AuthKind` enum in `app/rust/src/api/core.rs`, and regenerate.
   The app builds its auth form from `auth_choices()` and `auth_fields()`, so no Dart
   change is needed.
6. **Test it** in `auth/tests.rs`. Use published test vectors where the scheme has them.

## A new setting

Settings are one struct, `Settings` in `crates/reqorb-core/src/model.rs`, saved in the
workspace.

1. **Add the field** to `Settings`, with a doc comment, and a default in its `Default`
   impl. The struct is `#[serde(default)]`, so workspaces saved before the field existed
   still load.
2. **If it affects sending**, carry it into `SendOptions` in `send_options()`, and use it
   where sends read their options.
3. **Mirror it** in `_Settings` in `app/rust/src/api/core.rs`, and regenerate.
4. **Add it to `SettingsCopy.copyWith`** at the end of
   `app/lib/workspace/workspace_store.dart`. It is written by hand, and a field left out
   of it is silently reset whenever another setting changes.
5. **Show it** in `app/lib/settings/settings_dialog.dart` as a `_Row` with a label, help
   text that says what each value does, and a control with a `Key`.
6. **Test** the default and the round trip in the core, and the control in
   `app/test/settings_test.dart`.

## A new bridge call

When the app needs something from the core that `Engine` does not offer yet:

1. **Add the function** to `app/rust/src/api/core.rs`. Keep it thin: convert arguments,
   call the core, and map the error with `.map_err(|e| e.to_string())`. Make it
   `#[frb(sync)]` if it only computes and is quick; make it `async` if it touches the
   network or the disk, or could take long on a large input.
2. **Regenerate** the bridge.
3. **Add it to `Engine`** in `app/lib/bridge/engine.dart`: an abstract method with a doc
   comment, and its implementation in `RustEngine`, which calls the generated function.
4. **Add it to `FakeEngine`** in `app/test/fake_engine.dart`, recording calls and
   answering from a field a test can set.
5. **Call it from a model**, not a widget, so the state it changes is in one place.
6. **Test** the app side with `FakeEngine`, and the real call in an end-to-end test if
   the types it carries are new to the bridge.

## A new screen or feature in the app

- Put it in a folder under `app/lib/` named for the feature, or in the existing folder it
  belongs to.
- Keep state in a `ChangeNotifier` model; widgets listen with `ListenableBuilder` and
  call methods on it.
- Reach the engine only through `Engine.of(context)`, or through a model that holds the
  engine.
- Give every control a test drives a `Key`, and give the feature a test file in
  `app/test/`.
- Make it work at iPad width and in both themes: colours come from the theme's
  `ColorScheme`, never hard-coded.
- If it can be reached from the command palette, add it in
  `app/lib/palette/command_palette.dart`.
