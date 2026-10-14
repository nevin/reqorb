#!/usr/bin/env bash
# Builds the macOS app and packs it for a release:
#   scripts/package-macos.sh [out-dir]
#
# Signed with a Developer ID and notarized when these are set, as the release
# workflow sets them from the repository's secrets:
#   MACOS_SIGNING_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)",
#                            already in a keychain this user can use
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   for notarization
# Otherwise it is signed ad hoc, which runs here but which Gatekeeper refuses
# on other machines until they allow it.
set -euo pipefail

# Git Bash on Windows has one of these and macOS the other.
checksum() {
  if command -v sha256sum > /dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/dist}"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" | head -1)"
identity="${MACOS_SIGNING_IDENTITY:--}"

(cd "$root/app" && flutter build macos --release >&2)
app="$root/app/build/macos/Build/Products/Release/reqorb.app"
entitlements="$root/app/macos/Runner/Release.entitlements"

# Inside out: what the app holds is signed before the app itself, with the
# hardened runtime that notarization requires.
sign() {
  codesign --force --timestamp --options runtime --sign "$identity" "$@" >&2
}
if [[ "$identity" == "-" ]]; then
  sign() { codesign --force --sign - "$@" >&2; }
fi
find "$app/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  while IFS= read -r -d '' nested; do sign "$nested"; done
sign --entitlements "$entitlements" "$app"
codesign --verify --strict --deep "$app" >&2

mkdir -p "$out"
archive="$out/reqorb-$version-macos.zip"
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"

if [[ "$identity" != "-" && -n "${APPLE_ID:-}" ]]; then
  xcrun notarytool submit "$archive" --wait \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" >&2
  xcrun stapler staple "$app" >&2
  # The stapled ticket is in the app now, so it is packed again.
  rm -f "$archive"
  ditto -c -k --keepParent "$app" "$archive"
fi
(cd "$out" && checksum "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "$archive"
