#!/usr/bin/env bash
# Build a throwaway thurbox with this pane installed, and print its root.
#
# Nothing here can touch a real interface, a real database or a real tmux
# server: HOME and every XDG root point at a fresh mktemp directory, and
# TMUX_TMPDIR gives the server its own socket directory — the socket NAME is
# shared by every thurbox of the same build, so without that a teardown would
# kill sessions you have running.
#
# The pane is installed the way the README says to install it, from a local
# clone of THIS repository (`git+file://`), so what a recording shows is what a
# user gets — committed state, not the working tree. Set DEMO_SRC to install
# from somewhere else; demo/record.sh points it at the public repository so the
# line thurbox prints while trusting the pane names a URL anyone can type.
#
#   demo/sandbox.sh
#
# Prints the sandbox root on stdout. The caller owns teardown:
#   TMUX_TMPDIR=<root>/tmux tmux -L thurbox kill-server; rm -rf <root>
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI=${THURBOX_CLI:-thurbox-cli}
command -v "$CLI" >/dev/null || {
  echo "no thurbox-cli on PATH (set THURBOX_CLI)" >&2
  exit 2
}
command -v sqlite3 >/dev/null || {
  echo "sqlite3 is needed to skip the first-launch gate" >&2
  exit 2
}
command -v plannotator-tui >/dev/null || {
  echo "plannotator-tui is not on PATH — run scripts/install-plannotator.sh first" >&2
  exit 2
}

S=$(mktemp -d /tmp/thurbox-annotate-demo.XXXXXX)
export HOME="$S"
export XDG_CONFIG_HOME="$S/.config" XDG_DATA_HOME="$S/.local/share"
export XDG_STATE_HOME="$S/.local/state" XDG_CACHE_HOME="$S/.cache"
export TMUX_TMPDIR="$S/tmux"
# paths.rs honours these ahead of XDG, so an inherited one would defeat the
# isolation and point the sandbox at a real config.
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR
mkdir -p "$XDG_CONFIG_HOME/thurbox" "$XDG_DATA_HOME/thurbox" "$TMUX_TMPDIR"

# A stub agent that behaves like one worth reviewing: it prints a short plan with
# a deliberate flaw (step 2 measures bytes, not columns), then reads its stdin
# and echoes what arrives — so when the review is delivered with `session send`,
# the same pane visibly receives it. No API key, no real agent CLI.
cat >"$XDG_CONFIG_HOME/thurbox/agents.toml" <<'AGENTS'
default = "stub"

[[agents]]
name = "stub"
command = "sh"
args = [
  "-c",
  "printf '%s\\n' 'Plan for string width:' '' '  1. Parse the input string into chars.' '  2. Return input.len() as the width.' '  3. Add a test asserting width(\"hi\") == 2.' '' 'Waiting for review…'; while IFS= read -r line; do printf 'received > %s\\n' \"$line\"; done",
]
AGENTS

# A small repository so the session has a working directory.
R="$S/width-impl"
mkdir -p "$R/src"
printf '# width-impl\n\nString width, done right.\n' >"$R/README.md"
printf 'pub fn width(input: &str) -> usize {\n    input.len()\n}\n' >"$R/src/lib.rs"
git init -q "$R"
git -C "$R" add -A
git -C "$R" -c user.email=demo@example.com -c user.name=demo commit -qm 'initial'

# Installed, not copied: this is the flow the README documents, and it also
# materialises the base interface (lib/, layout.lua, the shipped panes) the pane
# needs around it. No layout edit and no bundled-pane removal — annotate shares
# the `center` switch slot with the agent pane, which the arrangement already
# places. DEMO_SRC defaults to a local clone so a recording reflects committed
# state, not the working tree; record.sh points it at the public repository.
SRC=${DEMO_SRC:-git+file://$REPO}
"$CLI" plugin install "$SRC" --as "plugins/40_annotate.lua" >/dev/null

# The binary the pane runs, vendored into the sandbox so it is self-contained.
mkdir -p "$S/.local/bin"
cp "$(command -v plannotator-tui)" "$S/.local/bin/plannotator-tui"

"$CLI" session create --name width-impl --repo-path "$R" --agent stub >/dev/null

# The first launch asks whether to continue to v2 and waits for an answer. A
# recording is about the pane, so the answer is recorded up front.
sqlite3 "$XDG_DATA_HOME/thurbox/thurbox.db" \
  "INSERT INTO metadata (key, value) VALUES ('v2_interface_acknowledged', '1')
   ON CONFLICT(key) DO UPDATE SET value = '1';"

"$CLI" plugin check --text >&2
echo "$S"
