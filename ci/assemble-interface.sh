#!/usr/bin/env bash
# Build the interface directory this pane is meant to live in, the way an install
# lays it out: thurbox's own `ui/` as the base, this repository cloned in beside
# it. Then `thurbox-cli plugin check` loads it, so a failure here is a failure a
# user would have seen on their own screen.
#
# Unlike a pane that adds a *column*, annotate needs no `layout.lua` edit: it
# shares the `center` slot with the bundled agent pane, which already declares
# `slot_mode = "switch"`, so the arrangement that places `center` places this too.
# It draws nothing until brought forward — its pill in the action band does that.
#
#   ci/assemble-interface.sh <thurbox-checkout> <output-dir>
set -euo pipefail

UPSTREAM=${1:?usage: assemble-interface.sh <thurbox-checkout> <output-dir>}
OUT=${2:?usage: assemble-interface.sh <thurbox-checkout> <output-dir>}
HERE=$(cd "$(dirname "$0")/.." && pwd)

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -r "$UPSTREAM/ui" "$OUT"

# Ours lands where `plugin install git+<url>` puts a cloned repository: a
# directory named after it, keeping its own `plugins/` prefix, so
# `require("lib.theme")` still resolves from the interface root exactly as it does
# after a real install. The launcher and delivery shim ride along because the
# whole repository is cloned; `plugin check` only loads the Lua, but the tree
# should match what a user gets.
mkdir -p "$OUT/thurbox-annotate/plugins" "$OUT/thurbox-annotate/bin"
cp "$HERE"/plugins/*.lua "$OUT/thurbox-annotate/plugins/"
cp "$HERE"/bin/*.sh "$OUT/thurbox-annotate/bin/"

cat >"$OUT/plugins.toml" <<'SPEC'
[[plugin]]
src = "git+https://github.com/spscream/thurbox-annotate"
file = "thurbox-annotate/plugins/40_annotate.lua"

[[plugin]]
src = "git+https://github.com/spscream/thurbox-annotate"
file = "thurbox-annotate/plugins/41_notes.lua"
SPEC

echo "assembled $OUT"
