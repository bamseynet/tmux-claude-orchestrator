#!/usr/bin/env bash
# _orch/trust.sh [<repo>] [--yes]            (issue #204)
# Get a repo past Claude Code's one-time folder-trust dialog so `orch spawn`
# into it works. Accepting trusts the repo's COMMITTED content (hooks,
# .mcp.json, settings, CLAUDE.md) and, because Claude keys trust by repo root,
# every future worktree of it. That is the operator's consent decision:
#   (no flag)  with a TTY: run `claude` in the repo root in the foreground; the
#              operator answers the dialog and /exit's. Without a TTY: print the
#              one-liner and exit 1 (an agent in a pane must escalate to the human).
#   --yes      non-interactive: start claude in a throwaway tmux window in the
#              repo ROOT, accept the dialog by Down+Enter only after the trust
#              regex confirms the dialog is on screen and the cursor row, wait
#              for claude to exit, kill only that window, append an audit event.
#              Policy: the orchestrator uses --yes only on repos it created at
#              the operator's request.
# Never writes Claude's config; it only re-reads it (repo_trust_state).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

repo=""; yes=""
for a in "$@"; do
  case "$a" in
    --yes) yes=1 ;;
    -*) say "trust: unknown flag '$a'" >&2; exit 1 ;;
    *) [ -z "$repo" ] || { say "trust: only one repo allowed" >&2; exit 1; }; repo="$a" ;;
  esac
done
repo="${repo:-${PROJECT_ROOT:-$(pwd)}}"
repo="$(_trust_repo_root "$repo")" || { say "trust: no such directory: $repo" >&2; exit 1; }

report_state() { # exits per resulting state
  if [ "$(repo_trust_state "$repo")" = trusted ]; then
    say "orch: $repo is trusted."; return 0
  fi
  say "orch: $repo is still not trusted (dialog not accepted, or Claude Code keys trust differently; see ORCH_SKIP_TRUST_CHECK)." >&2
  return 1
}

if [ "$(repo_trust_state "$repo")" = trusted ]; then
  say "orch: $repo is already trusted."; exit 0
fi

if [ -z "$yes" ]; then
  if [ -t 0 ] && [ -t 1 ] || [ "${ORCH_TRUST_FORCE_INTERACTIVE:-}" = 1 ]; then
    say "Trusting $repo also trusts its committed hooks/.mcp.json/settings. Answer the dialog, then /exit."
    (cd "$repo" && claude) || true
    report_state; exit $?
  fi
  say "orch: not trusted and no TTY. Ask the operator to run:  cd $repo && claude   (answer the trust dialog, then /exit)" >&2
  exit 1
fi

# --yes: throwaway window in the repo root.
S="$SESSION_NAME"
require_session_exists "$S"
wname="trust-$$"
wid="$(tmux new-window -d -P -F '#{window_id}' -t "$S:" -n "$wname" -c "$repo" claude 2>/dev/null)" || {
  say "trust: could not open a tmux window in session $S" >&2; exit 1; }
T="$S:$wid"
win_alive() { tmux list-windows -t "$S" -F '#{window_id}' 2>/dev/null | grep -qx "$wid"; }
cleanup() { win_alive && tmux kill-window -t "$T" 2>/dev/null || true; }
fail() { say "trust: $1" >&2; cleanup; exit 1; }

wait_s="${ORCH_TRUST_WAIT:-30}"
case "$wait_s" in ''|*[!0-9]*) wait_s=30 ;; esac

# 1) dialog really on screen, cursor on a known row.
i=0
until pane_has_trust_dialog "$T"; do
  i=$((i+1)); [ "$i" -le "$wait_s" ] || fail "trust dialog never appeared for $repo; sent no keys"
  sleep 1
done
# 2) move off the default "No, exit" row, then re-verify the cursor.
if pane_trust_cursor_on_no "$T"; then
  tmux send-keys -t "$T" Down
  i=0
  until pane_trust_cursor_on_yes "$T"; do
    i=$((i+1)); [ "$i" -le "$wait_s" ] || fail "cursor never reached 'Yes, I trust this folder'; not pressing Enter"
    sleep 1
  done
elif ! pane_trust_cursor_on_yes "$T"; then
  fail "cannot locate the cursor row of the trust dialog; not pressing Enter"
fi
# 3) accept.
tmux send-keys -t "$T" Enter
# 4) wait for the session to be usable, ask it to exit, wait for the window to go.
i=0
until is_ready "$T"; do
  win_alive || break
  i=$((i+1)); [ "$i" -le "$wait_s" ] || break
  sleep 1
done
if win_alive; then
  tmux send-keys -t "$T" -l '/exit'
  tmux send-keys -t "$T" Enter
  i=0
  while win_alive && [ "$i" -lt "$wait_s" ]; do i=$((i+1)); sleep 1; done
fi
cleanup

report_state || exit 1
ver="$(claude --version 2>/dev/null | awk '{print $1; exit}' || true)"
line="$(jq -nc --arg ts "$(date -u +%FT%TZ)" --arg repo "$repo" --arg who "${USER:-$(id -un 2>/dev/null || echo unknown)}" --arg v "${ver:-unknown}" \
  '{ts:$ts, id:"trust", event:"repo-trusted", repo:$repo, who:$who, claude_version:$v}')"
mkdir -p "$STATE_DIR"
printf '%s\n' "$line" >> "$STATE_DIR/events.jsonl"
log "trust: $repo trusted via --yes (claude $ver)"
