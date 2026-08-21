#!/usr/bin/env bash
# _orch/ask.sh <worker-id> <question...>
# Turns one-way signalling (send.sh) into request/response: send the question,
# wait for the worker to return to a ready prompt (i.e. it finished answering),
# then print its reply from the pane. (issue #18)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:?usage: ask.sh <worker-id> <question>}"; shift
msg="$*"
[ -n "$msg" ] || { say "usage: ask.sh <worker-id> <question>"; exit 1; }
require_valid_session_name
S="$SESSION_NAME"

# require_session_exists() (issue #96): a bare `-t "$S"` target matches by
# UNAMBIGUOUS PREFIX, so this could otherwise silently read/drive a DIFFERENT,
# longer-named live session's window instead of failing. Shared helper in
# lib.sh (issue #107) so this guard can't drift/be forgotten per-file.
require_session_exists "$S"

if ! tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null | grep -qx "$id"; then
  say "no worker window '$id' in session '$S'"; exit 1
fi

wait_ready "$S:$id" 30 || say "(warning: $id looks busy; asking anyway)"
send_prompt "$S:$id" "$msg"

if ! wait_ready "$S:$id" "${ORCH_ASK_TIMEOUT:-120}"; then
  say "(warning: $id did not return to ready within ${ORCH_ASK_TIMEOUT:-120}s; showing pane as-is)"
fi

pane_tail "$S:$id" "${ORCH_ASK_LINES:-40}"
