#!/usr/bin/env bash
# thurbox-annotate — Full-tier launcher.
#
# Started by the annotate pane as its program:
#
#     command("program", { text = "review", repo = <this>, args = { <uuid>, <label> } })
#
# tmux runs it with thurbox's own environment, so `thurbox-cli` and
# `plannotator-tui` are on PATH — but a program pane CANNOT be handed extra
# environment variables (the kernel spawns it with an empty extra-env set,
# `terminal/programs.rs`). So the whole herdr contract is assembled right here:
#
#   1. capture the agent's output into a markdown file,
#   2. point plannotator-tui at it,
#   3. wire delivery back to the same session through the sibling shim,
#
# which is what herdr's own `open.sh` does with env vars it CAN set.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SHIM="$HERE/pt-deliver.sh"

uuid=${1:-}
label=${2:-$uuid}

die() {
  printf '\n  thurbox-annotate: %s\n' "$*" >&2
  # Hold the pane open so the message is readable instead of a surface that
  # flashes a dead program.
  sleep 30
  exit 1
}

[ -n "$uuid" ] || die "no session was selected to review."
command -v plannotator-tui >/dev/null 2>&1 ||
  die "plannotator-tui is not on PATH — run scripts/install-plannotator.sh."
command -v thurbox-cli >/dev/null 2>&1 || die "thurbox-cli is not on PATH."
[ -x "$SHIM" ] || die "delivery shim missing or not executable: $SHIM"

CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/thurbox-annotate
mkdir -p "$CACHE"
doc="$CACHE/review-$uuid.md"

cap=$(thurbox-cli session capture "$uuid" --lines 400 --text 2>/dev/null || true)
[ -n "$cap" ] || cap="(could not capture the output of session $uuid)"

{
  printf '# Review — %s\n\n' "$label"
  printf 'Drag to select a line, comment, then press E to send the numbered feedback back to this agent.\n\n'
  # An indented code block, not a fenced one: the captured screen may itself
  # contain ``` and would break a fence. Four-space indent keeps every line on
  # its own row so a line is selectable, and survives any content.
  printf '%s\n' "$cap" | sed 's/^/    /'
} >"$doc"

export HERDR_ENV=1
export HERDR_BIN_PATH="$SHIM"
export PLANNOTATOR_TUI_FILE="$doc"
export PLANNOTATOR_TUI_DELIVER_TO="$uuid"
export HERDR_PANE_ID="$uuid"
# The footer reads "send → <label>"; focused_pane_id is the delivery fallback.
export HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\":\"$uuid\",\"focused_pane_agent\":\"$label\"}"

exec plannotator-tui "$doc"
