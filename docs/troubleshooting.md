# Troubleshooting

Problems you may run into while building, running or testing reqorb, with what causes
them and how to fix them.

## Building and running

### "Content hash on Dart side is different from Rust side" when the app starts

**Cause:** The generated Dart bindings and the Rust library were built from different
versions of `app/rust/src/api/`. This usually happens after changing the API without
regenerating, or after a pull that changed it while an old build was cached.

**Fix:** Regenerate the bindings, then run again:

```bash
cd app && flutter_rust_bridge_codegen generate && flutter run -d macos
```

If the bindings were already up to date, an old build is in the way: run
`flutter clean` first.

### The generator rewrites many files, or its output does not compile

**Cause:** Your `flutter_rust_bridge_codegen` is not the version the project uses. The
generator and the `flutter_rust_bridge` package must match exactly.

**Fix:** Install 2.13.0, the version in `app/pubspec.yaml`, and regenerate:

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
```

### A change to Rust does not show up in the running app

**Cause:** Hot reload reloads Dart only. The Rust library is built once, when the app
starts.

**Fix:** Do a full restart: press `R` in `flutter run`, or stop the app and run it again.

### The first build takes several minutes

This is expected. The first build compiles the Rust core and its dependencies, including
the JavaScript engine, gRPC and TLS. A release build of the macOS app compiles them twice,
once for Apple silicon and once for Intel. Later builds reuse what was compiled.

### "Swift Package Manager … will become an error in a future version of Flutter"

This warning comes from Flutter plugins that have not yet moved to Swift Package
Manager. It does not affect the build, and there is nothing to change in reqorb.

### The app's icon has no dark or tinted look

**Cause:** The build used Xcode older than 26, which cannot read `app/icon/AppIcon.icon`
and falls back to the light icons in the asset catalogs.

**Fix:** Build with Xcode 26 or later. [Releasing](releasing.md#the-app-icon) explains how
to check which icon a build contains.

### A Mac other than the one that built it will not open the app

**Cause:** Without a Developer ID, `scripts/package-macos.sh` signs the app ad hoc, and
Gatekeeper refuses ad hoc apps that come from another machine.

**Fix:** For your own use, allow it once in **System Settings › Privacy & Security**. To
share it, sign and notarize it as described in [Releasing](releasing.md#signing-the-macos-app).

## Credentials

### Settings says saved credentials are locked

**Cause:** The workspace's credentials were encrypted with a key the app cannot read now.
Usually `workspace.json` was copied from another machine, or the keychain item was removed
(service `reqorb`, account `workspace-key`) or access to it was refused.

**Fix:** Nothing else is affected. Enter the locked values again, and they are encrypted
with this machine's key. If you refused a keychain prompt, run the app again and allow
it.

### Settings says credentials are "Not encrypted"

**Cause:** No system keychain could be used, so credentials are saved as plain text.
On Linux this means no Secret Service is running (GNOME Keyring or KWallet provide one).

**Fix:** Start a Secret Service and run the app again, or accept plain text for a
throwaway workspace.

## Testing

### The end-to-end tests stall, or taps land in the wrong place

**Cause:** These tests drive the real window. They stall when the display sleeps, and
taps go astray when another window takes focus.

**Fix:** Run them with `caffeinate -d` and leave the machine alone until they finish:

```bash
cd app && caffeinate -d flutter test integration_test -d macos
```

For everyday work, `flutter test` covers the app without a window.

### A widget test never sees work that runs in the background

**Cause:** Widget tests run on a fake clock, so work handed to `Isolate.run` never
completes on its own.

**Fix:** Wait for it in real time inside `tester.runAsync`, then pump.
[Testing](testing.md#app-tests) has the loop to copy.

### `scripts/coverage.sh` fails before measuring anything

**Cause:** `cargo-llvm-cov` is missing, or so is the Rust component it needs.

**Fix:**

```bash
cargo install cargo-llvm-cov
rustup component add llvm-tools-preview
```

### CI fails on "Dependency advisories" with no code change

**Cause:** `cargo audit` found a newly published vulnerability in a crate the build uses.

**Fix:** Run `cargo audit` locally to see which crate and which versions are fixed, then
update it with `cargo update -p <crate>`. If no fixed version exists yet, raise it rather
than silencing the check.
