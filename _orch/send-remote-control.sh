#!/usr/bin/env bash
# _orch/send-remote-control.sh — type "/remote-control" into the
# ORCHESTRATOR's own Claude Code pane and submit it.
#
# Targets the master/orchestrator window ($SESSION_NAME:$ORCH_WINDOW, default
# orch-<hash of this toolkit's root>:orchestrator — see lib.sh) — NOT a worker
# session the orchestrator drives. Override with an explicit "<session:window>"
# arg or the $ORCH_TARGET env var if needed.
#
# Usage (normally invoked via the `./orch remote-control` subcommand; can
# also be run directly, e.g. from cron):
#   ./orch remote-control                 # -> $SESSION_NAME:$ORCH_WINDOW
#   ./orch remote-control orch:orchestrator
#   ./orch remote-control --force         # bypass the unsent-draft guard
#   SESSION_NAME=foo ORCH_WINDOW=bar ./orch remote-control
set -euo pipefail

CMD="/remote-control"

# --force bypasses the draft guard (send even if the pane holds an unsent draft).
force=0
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--force] [<session:window>]" >&2
      echo "  Types '$CMD' into \$SESSION_NAME:\$ORCH_WINDOW (or the given target) and submits it." >&2
      echo "  --force  send even if the pane holds an unsent draft." >&2
      exit 0
      ;;
    -*) echo "$0: unknown option: $1" >&2; exit 2 ;;
    *)
      [ -n "$target" ] && { echo "$0: unexpected extra argument: $1" >&2; exit 2; }
      target="$1"; shift
      ;;
  esac
done

# This script ships INSIDE the toolkit (installed alongside lib.sh by
# install.sh), so _orch/lib.sh is always expected to sit right next to it. A
# missing lib means a broken/partial checkout, not a case to silently degrade
# for: without it we'd have no pane_has_draft() guard and could clobber an
# unsent operator draft in the master pane, and no per-install SESSION_NAME
# hash (issue #81) to pick the right session — a guessed "orch" default could
# silently target a stale or unrelated session. Fail loudly instead.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$here/lib.sh" ]; then
  echo "$0: lib.sh not found at $here/lib.sh — broken checkout?" >&2
  exit 1
fi
# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$here/lib.sh"   # provides SESSION_NAME, ORCH_WINDOW, send_prompt(), pane_has_draft()

# Resolve the target: explicit arg > $ORCH_TARGET > the orchestrator window.
target="${target:-${ORCH_TARGET:-${SESSION_NAME}:${ORCH_WINDOW}}}"

command -v tmux >/dev/null 2>&1 || { say "tmux not found" >&2; exit 1; }
tmux has-session -t "${target%%:*}" 2>/dev/null || {
  say "no such tmux session: ${target%%:*}" >&2; exit 1; }
tmux list-windows -t "${target%%:*}" -F '#S:#W' 2>/dev/null | grep -qxF -- "$target" \
  || tmux display-message -t "$target" -p '' >/dev/null 2>&1 \
  || { say "no such tmux window: $target" >&2; exit 1; }

# Draft guard: never clobber an unsent operator draft in the orchestrator pane
# (issue #38/#52). If the pane's true last input line holds a draft, skip this
# tick — a keepalive can safely wait for the next one. --force overrides.
if [ "$force" -eq 0 ] && pane_has_draft "$target"; then
  say "skip: '$target' has an unsent draft; not sending (use --force to override)"
  exit 0
fi

# Deliver the command via the toolkit's hardened send_prompt (bracketed paste
# + Enter gated on the paste landing).
send_prompt "$target" "$CMD"

say "sent '$CMD' to $target"
