#!/usr/bin/env bash
# Measures how much of the code the tests run, and fails when it falls
# below the floor: the Rust crates by their own tests, and the app by its
# widget and logic tests (the end-to-end ones are not counted).
#   scripts/coverage.sh
# Needs cargo-llvm-cov (`cargo install cargo-llvm-cov`) and Flutter.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# A little under what the tests reach today; raise them as tests are added.
rust_floor="${RUST_COVERAGE_FLOOR:-90}"
dart_floor="${DART_COVERAGE_FLOOR:-80}"

echo "Rust (lines, at least $rust_floor%):"
# The bridge crate is code the app's tests exercise, not Rust's.
cargo llvm-cov --manifest-path "$root/Cargo.toml" --workspace --exclude rust_lib_reqorb \
  --summary-only --fail-under-lines "$rust_floor" | grep -E '^TOTAL'

echo "App (lines, at least $dart_floor%):"
(cd "$root/app" && flutter test --coverage > /dev/null)
# The bindings are generated, and tested from the other side.
awk -v floor="$dart_floor" '
  /^SF:/ { own = $0 !~ /\/src\/rust\// }
  own && /^LF:/ { found += substr($0, 4) }
  own && /^LH:/ { hit += substr($0, 4) }
  END {
    cover = 100 * hit / found
    printf "TOTAL %d of %d lines, %.2f%%\n", hit, found, cover
    if (cover < floor) { print "below the floor of " floor "%"; exit 1 }
  }
' "$root/app/coverage/lcov.info"
