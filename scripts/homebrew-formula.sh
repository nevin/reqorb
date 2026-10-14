#!/usr/bin/env bash
# Writes a Homebrew formula for the CLI archives of one release:
#   scripts/homebrew-formula.sh <version> <dir-with-archives> > reqorb.rb
# Put it in a tap (a repository named homebrew-<name>) to install with
# `brew install <owner>/<name>/reqorb`.
set -euo pipefail

version="$1"
dir="$2"
base="https://github.com/nevin/reqorb/releases/download/v$version"

sha() { cut -d' ' -f1 < "$dir/reqorb-$version-$1.tar.gz.sha256"; }

cat <<RUBY
class Reqorb < Formula
  desc "Send, test and document HTTP, GraphQL, WebSocket and gRPC requests"
  homepage "https://github.com/nevin/reqorb"
  version "$version"
  license "MIT"

  on_macos do
    on_arm do
      url "$base/reqorb-$version-aarch64-apple-darwin.tar.gz"
      sha256 "$(sha aarch64-apple-darwin)"
    end
    on_intel do
      url "$base/reqorb-$version-x86_64-apple-darwin.tar.gz"
      sha256 "$(sha x86_64-apple-darwin)"
    end
  end

  on_linux do
    on_intel do
      url "$base/reqorb-$version-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "$(sha x86_64-unknown-linux-gnu)"
    end
  end

  def install
    bin.install "reqorb"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/reqorb --version")
  end
end
RUBY
