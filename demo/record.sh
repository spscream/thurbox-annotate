#!/usr/bin/env bash
# Record media/demo.gif: the real TUI, in a throwaway thurbox this pane was
# installed into. It reviews a stub agent's plan in plannotator-tui and sends the
# feedback back — every key a key a user presses.
#
# asciinema records the pty and agg rasterises the cast — not VHS, which drives a
# headless browser and could not emit an F-key even if it worked here.
#
# Needs: asciinema, agg, tmux, git, sqlite3, plannotator-tui and a thurbox on
# PATH. See demo/sandbox.sh for what is thrown away afterwards.
#
#   demo/record.sh [output.gif]
#
# SNAP=<dir> writes what the screen held at each step there, which is the only
# way to tell a key that missed from a key that landed on the wrong row: the cast
# is gone with the sandbox by the time the GIF looks wrong.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/media/demo.gif}
THURBOX=${THURBOX:-thurbox}
COLS=${COLS:-150}
ROWS=${ROWS:-42}
SNAP=${SNAP:-}
export DEMO_SRC=${DEMO_SRC:-git+https://github.com/spscream/thurbox-annotate}

missing=
for tool in asciinema agg tmux git sqlite3 plannotator-tui "$THURBOX"; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done
[ -n "$missing" ] && {
  echo "missing:$missing" >&2
  exit 2
}

S=$("$REPO/demo/sandbox.sh")
TM="tmux -L thurbox-annotate-demo"
cleanup() {
  TMUX_TMPDIR="$S/tmux" $TM kill-server 2>/dev/null || true
  TMUX_TMPDIR="$S/tmux" tmux -L thurbox kill-server 2>/dev/null || true
  rm -rf "$S"
}
trap cleanup EXIT INT TERM

cat >"$S/run.sh" <<RUN
#!/usr/bin/env bash
export HOME="$S"
export XDG_CONFIG_HOME="$S/.config" XDG_DATA_HOME="$S/.local/share"
export XDG_STATE_HOME="$S/.local/state" XDG_CACHE_HOME="$S/.cache"
export TMUX_TMPDIR="$S/tmux"
export PATH="$HOME/.local/bin:$PATH"
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR
cd "$S/width-impl"
exec $(command -v "$THURBOX")
RUN
chmod +x "$S/run.sh"

export TMUX_TMPDIR="$S/tmux"
CAST="$S/demo.cast"
$TM new-session -d -x "$COLS" -y "$ROWS" \
  "asciinema rec --overwrite --quiet --command '$S/run.sh' '$CAST'"

# One key, then a pause long enough to read what it did. `send-keys` reaches the
# recorded program, so what lands in the cast is the real interface reacting.
k() {
  $TM send-keys -t 0 "$1"
  sleep "${2:-0.8}"
}
# Literal text (a comment body), typed as one paste rather than key by key.
type() {
  $TM send-keys -t 0 -l "$1"
  sleep "${2:-0.6}"
}
snap() {
  [ -n "$SNAP" ] && $TM capture-pane -p -t 0 >"$SNAP/$1.txt"
  true
}
[ -n "$SNAP" ] && mkdir -p "$SNAP"

# Wait for the first frame rather than guessing: a cold start reads the DB, boots
# tmux and spawns the session.
for _ in $(seq 1 40); do
  $TM capture-pane -p -t 0 2>/dev/null | grep -q 'Sessions' && break
  sleep 1
done
sleep 3
snap 0-boot

# ── Trust the pane ──────────────────────────────────────────────────────────
# `program`, pressed rather than seeded: this is thurbox's own flow — F6, ] for
# the Interface tab, `t` on the pane — and it is in the recording because a pane
# you have not trusted draws a different thing. The number of `j` steps to reach
# the annotate row is calibrated from SNAP (see 1-interface).
k F6 1.5
k "]" 1.2
snap 1-interface
k j 0.4
k t 1.2
snap 2-trusted
k Escape 2

# ── Open the review ─────────────────────────────────────────────────────────
# F4 brings the review pane forward and starts plannotator-tui on the selected
# session's captured output.
k F4 3
snap 3-review-open

# ── Annotate ────────────────────────────────────────────────────────────────
# j to the code block (heading, instruction, then the captured plan), c to
# comment on it, type the note, submit.
k j 0.6
k j 1.0
snap 4-block
k c 1.0
snap 5-comment-open
type "step 2: input.len() counts bytes, not columns — use unicode-width" 0.8
k Enter 1.5
snap 6-comment-made

# ── Send it back to the agent ───────────────────────────────────────────────
k E 2
snap 7-sent

# Close the review; the agent pane received the feedback through `session send`.
k F4 2.5
snap 8-delivered

# A beat on the result before quitting: the last frame of a looping GIF is on
# screen as long as the first.
sleep 3

# Quit, which ends the recording: asciinema writes the cast when the command it
# wrapped exits.
k C-q 3
for _ in $(seq 1 20); do
  [ -s "$CAST" ] && break
  sleep 1
done

# A GIF loops, so its last frame is on screen as long as its first. Cut the cast
# where teardown starts: thurbox runs with the cursor hidden, so the cursor
# coming back (or the alternate screen going away) is the first byte of the exit.
python3 - "$CAST" <<'TRIM'
import json, sys

path = sys.argv[1]
lines = open(path).read().splitlines()
for i, line in enumerate(lines[1:], start=1):  # line 0 is the header
    data = json.loads(line)[2]
    if "\x1b[?25h" in data or "\x1b[?1049l" in data:
        open(path, "w").write("\n".join(lines[:i]) + "\n")
        break
TRIM

mkdir -p "$(dirname "$OUT")"
agg --font-size 14 --idle-time-limit 1.5 --theme asciinema "$CAST" "$OUT"
ls -lh "$OUT"
