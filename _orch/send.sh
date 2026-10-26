#!/usr/bin/env bash
# _orch/send.sh <worker-id> <message...>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:?usage: send.sh <worker-id> <message>}"; shift
msg="$*"
require_valid_session_name
S="$SESSION_NAME"

# require_session_exists() (issue #107): a bare `-t "$S"` target matches by
# UNAMBIGUOUS PREFIX, so list-windows/paste-buffer/send-keys below could otherwise
# silently type into a DIFFERENT, longer-named live session's window instead of
# failing (issue #96 fixed the read-only existence checks; this closes the write
# paths). Shared helper in lib.sh so this guard can't drift/be forgotten per-file.
require_session_exists "$S"

if ! tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null | grep -qx "$id"; then
  say "no worker window '$id' in session '$S'"; exit 1
fi

# Issue #155: a paste's trailing Enter selects a dialog's highlighted choice (the
# trust dialog's default exits the session). Refuse free text while a dialog is up;
# a bare numeric answer ("orch send <id> 1") is the deliberate way to answer one.
# The wait ends early on a dialog, so one that renders mid-wait is caught too.
wr=0; wait_ready_or_dialog "$S:$id" 30 || wr=$?
if [ "$wr" -eq 2 ] && ! [[ "$msg" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
  say "$id is showing a dialog (not ready); not sending. Answer it with a number, e.g. \`orch send $id 1\`"
  exit 1
fi
[ "$wr" -ne 1 ] || say "(warning: $id looks busy; sending anyway)"
send_prompt "$S:$id" "$msg"
say "sent to $id"
