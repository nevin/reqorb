#!/usr/bin/env bash
# Builds the reqorb CLI for one target and packs it for a release:
#   scripts/package-cli.sh [target] [out-dir]
# The target defaults to this machine's. Prints the archive's path.
set -euo pipefail

# Git Bash on Windows has one of these and macOS the other.
checksum() {
  if command -v sha256sum > /dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-$(rustc -vV | sed -n 's/^host: //p')}"
out="${2:-$root/dist}"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" | head -1)"

cargo build --manifest-path "$root/Cargo.toml" --release --locked -p reqorb-cli --target "$target" >&2

name="reqorb-$version-$target"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name" "$out"
# A full path: the Windows archive is made from inside the staging folder,
# where a relative one would point somewhere else.
out="$(cd "$out" && pwd)"
binary="reqorb"
[[ "$target" == *windows* ]] && binary="reqorb.exe"
cp "$root/target/$target/release/$binary" "$root/README.md" "$root/LICENSE" "$stage/$name/"

if [[ "$target" == *windows* ]]; then
  archive="$out/$name.zip"
  (cd "$stage" && 7z a -tzip "$archive" "$name" >&2)
else
  archive="$out/$name.tar.gz"
  tar -C "$stage" -czf "$archive" "$name"
fi
(cd "$out" && checksum "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "$archive"
