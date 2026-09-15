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

# Prefer the agent's actual last reply — clean Markdown read from its transcript
# — the way herdr-annotate's own "review the agent's last reply" (annotate.last)
# does. plannotator-tui is a Markdown annotator: a rendered-screen scrape comes
# out as fragmented code blocks, while a real reply renders as itself. thurbox
# names the agent and its session id, which is exactly what `plannotator-tui
# last` needs to read the right transcript.
meta=$(thurbox-cli session get "$uuid" --json 2>/dev/null || true)
field() {
  [ -n "$meta" ] || return 0
  printf '%s' "$meta" |
    python3 -c "import sys,json; print(json.load(sys.stdin).get('$1') or '')" 2>/dev/null || true
}
remote=$(field remote_host)
session_id=$(field agent_session_id)
# The agent thurbox thinks is here, mapped to a host plannotator knows how to
# read. `reports_as`/`detected_agent` win over the configured name, since a
# session may run claude under a custom agent label.
host=""
for candidate in "$(field reports_as)" "$(field detected_agent)" "$(field agent)"; do
  lower=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
  claude | codex | pi | omp | copilot | droid | hermes | opencode)
    host="$lower"
    break
    ;;
  esac
done

# Read the reply only for a local session whose agent plannotator knows and
# whose transcript exists yet; anything else falls back to the screen.
reply=""
if [ -z "$remote" ] && [ -n "$host" ] && [ -n "$session_id" ]; then
  reply=$(plannotator-tui last --host "$host" --session-id "$session_id" --print 2>/dev/null || true)
fi

{
  printf '# Review — %s\n\n' "$label"
  printf 'Drag to select a line, comment, then press E to send the numbered feedback back to this agent.\n\n'
  if [ -n "$reply" ]; then
    # Already Markdown — pass the agent's reply through untouched.
    printf '%s\n' "$reply"
  else
    # No transcript to read (a shell agent, a remote session, or one that has
    # not replied yet): fall back to the rendered screen. An indented code
    # block, not a fenced one — the screen may itself contain ``` and would
    # break a fence; four-space indent keeps every line selectable.
    cap=$(thurbox-cli session capture "$uuid" --lines 400 --text 2>/dev/null || true)
    [ -n "$cap" ] || cap="(could not read this session's last reply or capture its screen)"
    printf '%s\n' "$cap" | sed 's/^/    /'
  fi
} >"$doc"

export HERDR_ENV=1
export HERDR_BIN_PATH="$SHIM"
export PLANNOTATOR_TUI_FILE="$doc"
export PLANNOTATOR_TUI_DELIVER_TO="$uuid"
export HERDR_PANE_ID="$uuid"
# The footer reads "send → <label>"; focused_pane_id is the delivery fallback.
export HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\":\"$uuid\",\"focused_pane_agent\":\"$label\"}"

exec plannotator-tui "$doc"
