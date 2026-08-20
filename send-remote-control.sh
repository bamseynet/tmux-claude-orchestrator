#!/usr/bin/env bash
# send-remote-control.sh — type "/remote-control" into the ORCHESTRATOR's own
# Claude Code pane and submit it.
#
# Targets the master/orchestrator window ($SESSION_NAME:$ORCH_WINDOW, default
# orch-<hash of this toolkit's root>:orchestrator — see _orch/lib.sh) — NOT a
# worker session the orchestrator drives. Override with an explicit
# "<session:window>" arg or the $TARGET env var if needed.
#
# Usage:
#   ./send-remote-control.sh                 # -> $SESSION_NAME:$ORCH_WINDOW
#   ./send-remote-control.sh orch:orchestrator
#   SESSION_NAME=foo ORCH_WINDOW=bar ./send-remote-control.sh
#   ./send-remote-control.sh --force          # bypass the unsent-draft guard
set -euo pipefail

CMD="/remote-control"

# --force bypasses the draft guard (send even if the pane holds an unsent draft).
force=0
if [ "${1:-}" = "--force" ]; then force=1; shift; fi

# This script ships INSIDE the toolkit, so _orch/lib.sh is always expected to
# be right next to it. A missing lib means a broken/partial checkout, not a
# case to silently degrade for: without it we'd have no pane_has_draft() guard
# and could clobber an unsent operator draft in the master pane, and no
# per-install SESSION_NAME hash (issue #81) to pick the right session — a
# guessed "orch" default could silently target a stale or unrelated session.
# Fail loudly instead.
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_orch/lib.sh"
if [ ! -f "$lib" ]; then
  echo "send-remote-control.sh: _orch/lib.sh not found at $lib — broken checkout?" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$lib"   # provides SESSION_NAME, ORCH_WINDOW, send_prompt(), pane_has_draft()

# Resolve the target: explicit arg > $TARGET > the orchestrator window.
target="${1:-${TARGET:-${SESSION_NAME}:${ORCH_WINDOW}}}"

command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 1; }
tmux has-session -t "${target%%:*}" 2>/dev/null || {
  echo "no such tmux session: ${target%%:*}" >&2; exit 1; }
tmux list-windows -t "${target%%:*}" -F '#S:#W' 2>/dev/null | grep -qx "$target" \
  || tmux display-message -t "$target" -p '' >/dev/null 2>&1 \
  || { echo "no such tmux window: $target" >&2; exit 1; }

# Draft guard: never clobber an unsent operator draft in the orchestrator pane
# (issue #38/#52). If the pane's true last input line holds a draft, skip this
# tick — a keepalive can safely wait for the next one. --force overrides.
if [ "$force" -eq 0 ] && pane_has_draft "$target"; then
  echo "skip: '$target' has an unsent draft; not sending (use --force to override)"
  exit 0
fi

# Deliver the command via the toolkit's hardened send_prompt (bracketed paste
# + Enter gated on the paste landing).
send_prompt "$target" "$CMD"

echo "sent '$CMD' to $target"
