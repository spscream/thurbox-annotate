#!/usr/bin/env bash
# thurbox-annotate — herdr delivery shim.
#
# When HERDR_ENV=1, plannotator-tui delivers a review by running its herdr
# binary as:
#
#     $HERDR_BIN_PATH agent prompt <pane> <feedback>
#
# with the whole feedback as ONE argument (docs/spec-herdr-integration.md in the
# plannotator-tui repo). We are that binary. thurbox has no "herdr", so we
# translate the call into thurbox's own channel — `session send` types the text
# into the target session's terminal as one bracketed paste followed by Enter,
# which is exactly the delivery semantics the spec verified herdr uses.
#
# Any other call shape (herdr probes such as `agent pane`) is a silent success:
# the delivery target is resolved from the environment, not from this binary.
set -euo pipefail

if [ "${1:-}" = "agent" ] && [ "${2:-}" = "prompt" ]; then
  pane=${3:-${PLANNOTATOR_TUI_DELIVER_TO:-${HERDR_PANE_ID:-}}}
  text=${4:-}
  # The spec passes feedback in argv; tolerate stdin too, but never block on a
  # tty when there is neither.
  if [ -z "$text" ] && [ ! -t 0 ]; then
    text=$(cat)
  fi
  [ -n "$pane" ] || {
    echo "pt-deliver: no target session (pane / DELIVER_TO / PANE_ID all empty)" >&2
    exit 2
  }
  [ -n "$text" ] || {
    echo "pt-deliver: empty feedback, nothing to send" >&2
    exit 0
  }
  if [ -n "${PT_DELIVER_DRYRUN:-}" ]; then
    printf 'DRYRUN session send %s <<%s>>\n' "$pane" "$text"
    exit 0
  fi
  exec thurbox-cli session send "$pane" "$text"
fi

exit 0
