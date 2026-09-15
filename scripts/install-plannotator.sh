#!/usr/bin/env bash
# Install the plannotator-tui binary the annotate pane runs.
#
# It is a standalone MIT program (github.com/plannotator/plannotator-tui) shipped
# as a checksummed per-platform release binary — nothing is built here, matching
# the "never build under the interface directory" rule. This downloads the right
# asset, verifies it against the release SHA256SUMS, and installs it.
#
#   scripts/install-plannotator.sh [version] [dest-dir]
#
# Defaults: latest known-good version, into ~/.local/bin (must be on PATH).
set -euo pipefail

VERSION=${1:-v0.8.0}
DEST=${2:-$HOME/.local/bin}
REPO="plannotator/plannotator-tui"

os=$(uname -s)
arch=$(uname -m)
case "$os-$arch" in
  Linux-x86_64) asset="plannotator-tui-x86_64-unknown-linux-gnu" ;;
  Linux-aarch64 | Linux-arm64) asset="plannotator-tui-aarch64-unknown-linux-gnu" ;;
  Darwin-x86_64) asset="plannotator-tui-x86_64-apple-darwin" ;;
  Darwin-arm64) asset="plannotator-tui-aarch64-apple-darwin" ;;
  *)
    echo "no prebuilt plannotator-tui for $os-$arch; build from source instead" >&2
    exit 1
    ;;
esac

base="https://github.com/$REPO/releases/download/$VERSION"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading $asset ($VERSION)…"
curl -sSfL -o "$tmp/$asset" "$base/$asset"
curl -sSfL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"

echo "verifying checksum…"
want=$(grep " $asset\$" "$tmp/SHA256SUMS" | awk '{print $1}')
got=$(sha256sum "$tmp/$asset" | awk '{print $1}')
if [ -z "$want" ] || [ "$want" != "$got" ]; then
  echo "checksum mismatch for $asset: want=$want got=$got" >&2
  exit 1
fi

mkdir -p "$DEST"
install -m 0755 "$tmp/$asset" "$DEST/plannotator-tui"
echo "installed plannotator-tui $VERSION → $DEST/plannotator-tui"
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "note: $DEST is not on PATH; add it so the annotate pane can find plannotator-tui" >&2 ;;
esac
