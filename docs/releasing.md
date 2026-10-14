# Releasing

## Cutting a version

1. **Set the version** in two places, to the same value:
   - `Cargo.toml`: `version` under `[workspace.package]`. All the crates share it.
   - `app/pubspec.yaml`: `version`. The part before any `+` must match.
2. **Update the changelog.** In `CHANGELOG.md`, rename **Unreleased** to the version and
   the date (`## 0.2.0 – 2026-11-02`) and start a new, empty **Unreleased** above it.
   Read the entries through as a user would; they become the release notes.
3. **Commit** the changes and push them to `main`. Wait for CI to pass on that commit.
4. **Tag** the commit and push the tag:

   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```

5. **Write the release notes.** The workflow creates the release with notes GitHub
   generates from the commits. Replace them on GitHub with the version's changelog
   entries, and say whether the macOS app is notarized.

Pushing a tag that starts with `v` runs `.github/workflows/release.yml`:

| Job | What it does |
|---|---|
| Tag matches the version | Fails the release if the tag, `Cargo.toml` and `pubspec.yaml` disagree |
| CLI | Builds `reqorb` for macOS (Apple silicon and Intel), Linux (x86-64) and Windows (x86-64) with `scripts/package-cli.sh` |
| macOS app | Builds a universal app, signs it, notarizes it when it can, and zips it with `scripts/package-macos.sh` |
| Publish the release | Creates the GitHub release with every archive, a SHA-256 checksum for each, and notes generated from the commits |

There are no iPad, Windows app or Linux app builds in the release yet.

## Signing the macOS app

The app is signed with a Developer ID and notarized when the repository has these
secrets, and signed ad hoc otherwise:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | The Developer ID Application certificate and its key, as base64 of a `.p12` file |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12` file's password |
| `MACOS_SIGNING_IDENTITY` | The identity's name, such as `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | For notarization. The password is an app-specific one from appleid.apple.com |

An ad hoc signed app runs on the Mac that built it. Other Macs refuse to open it until
it is allowed in **System Settings › Privacy & Security**. Say so in the release notes
whenever a release is not notarized.

## Building a release locally

The same scripts the workflow uses write to `dist/`:

```bash
scripts/package-cli.sh                    # the CLI, for this machine
scripts/package-cli.sh x86_64-apple-darwin
scripts/package-macos.sh                  # the macOS app, signed ad hoc
```

To sign and notarize locally, set the variables listed at the top of
`scripts/package-macos.sh` first. The certificate must already be in a keychain you can
use.

## The app icon

The icon has a light, a dark and a tinted look on iOS and macOS, and one look on
Windows.

| File | Used by |
|---|---|
| `app/icon/AppIcon.icon` | iOS and macOS, built with Xcode 26 or later. An Icon Composer file holding the light, dark and tinted looks; both Xcode projects reference this one copy |
| `app/ios/Runner/Assets.xcassets/AppIcon.appiconset` | iOS with an older Xcode: light, dark and tinted 1024 px images, opaque |
| `app/macos/Runner/Assets.xcassets/AppIcon.appiconset` | macOS with an older Xcode: the light icon at each size, on a rounded tile with a transparent margin |
| `app/windows/runner/resources/app_icon.ico` | Windows: the dark tile, from 16 to 256 px |

When Xcode 26 or later builds the app, it uses `AppIcon.icon` and ignores the asset
catalogs' icon sets, so the fallbacks matter only for older Xcode versions.

To change the icon:

1. **Edit `app/icon/AppIcon.icon`** in Icon Composer (in Xcode: **Xcode › Open Developer
   Tool › Icon Composer**). It has a background colour per appearance and three artwork
   layers, each shown in one appearance only: `light`, `dark`, and `tinted`.
2. **Check every look** without changing your Mac's appearance, with the renderer that
   ships with Icon Composer:

   ```bash
   ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
   for look in Default Dark TintedDark; do
     "$ictool" app/icon/AppIcon.icon --export-image --output-file /tmp/icon-$look.png \
       --platform iOS --rendition $look --width 1024 --height 1024 --scale 1
   done
   ```

   Use `--platform macOS` for the Mac's shape.
3. **Update the fallbacks** from the same artwork: the three iOS images, the seven macOS
   sizes, and the Windows `.ico`. The iOS images must have no alpha channel, or the App
   Store rejects them; check with `sips -g hasAlpha`.
4. **Confirm the build picked it up:**

   ```bash
   cd app && flutter build macos --debug
   xcrun assetutil --info build/macos/Build/Products/Debug/reqorb.app/Contents/Resources/Assets.car \
     | grep '"Appearance"' | sort | uniq -c
   ```

   Both `NSAppearanceNameAqua` and `NSAppearanceNameDarkAqua` should be listed.
