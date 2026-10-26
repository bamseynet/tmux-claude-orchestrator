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
# a bare option number ("orch send <id> 1") answers a permission dialog or selector (typed, #192).
# The wait ends early on a dialog, so one that renders mid-wait is caught too.
wr=0; wait_ready_or_dialog "$S:$id" 30 || wr=$?
# Type option <n> as one literal keypress (no paste, no Enter) and exit. Both the
# selector and the permission dialog silently ignore a digit with no matching
# row; reporting it as typed would leave the caller believing a still-blocked
# worker was answered, so the cursor's own option list must show it first.
type_option() { # <n> <dialog name> <note>
  if ! pane_option_visible "$S:$id" "$1"; then
    say "$id's $2 shows no option $1; not sending. Check the pane for the option numbers"
    exit 1
  fi
  tmux send-keys -t "$S:$id" -l "$1"
  say "typed option $1 into $id's $2 ($3)"
  exit 0
}
# Issue #189: the AskUserQuestion selector ignores a pasted digit, and the
# paste's Enter then answers with the HIGHLIGHTED option -- "orch send <id> 2"
# picked 1. A typed digit selects (and advances) on its own, so type exactly one
# and no Enter; a second digit would answer the next question unseen. In a
# multi-select question the digit only toggles that option. Free text is pasted
# (with Enter) only once the cursor is on the "Type something." row, whose
# footer adds the ctrl+g editor hint: there the paste fills the row and Enter
# submits it (all live-checked on 2.1.310).
if [ "$wr" -eq 2 ] && pane_has_askuser_dialog "$S:$id"; then
  if pane_has_askuser_text_entry "$S:$id"; then
    # A bare digit here is far likelier a change of mind ("pick option 2") than
    # the intended free-text answer; submitting it as text would answer unseen.
    if [[ "$msg" =~ ^[[:space:]]*[0-9]*[[:space:]]*$ ]]; then
      say "$id's question selector is on its free-text row; not sending. Send the answer text, or move the cursor off that row in the pane first"
      exit 1
    fi
    send_prompt "$S:$id" "$msg"
    say "sent as the free-text answer on $id"
    exit 0
  fi
  if ! [[ "$msg" =~ ^[[:space:]]*([1-9])[[:space:]]*$ ]]; then
    say "$id is showing a question selector; not sending. Answer it with one option number, e.g. \`orch send $id 1\` (pick its \"Type something.\" number first to send free text)"
    exit 1
  fi
  type_option "${BASH_REMATCH[1]}" "question selector" "a multi-select question only toggles it; check the pane"
fi
# Issue #192: the permission and trust dialogs ignore a PASTED digit too, and the
# paste's Enter then takes the highlighted default ("1. Yes" approved a tool call
# meant to be refused with 4; "No, exit" killed the worker). No dialog option is
# ever picked by paste. Permission: type the digit as a keypress (no Enter) once its
# own option block shows it. Trust: its digit handling is unverified (the 2.1.310
# capture has no numbers), and mapping N to arrow presses blind is the same
# act-on-a-guess hazard, so refuse.
if [ "$wr" -eq 2 ]; then
  if pane_has_trust_dialog "$S:$id"; then
    say "$id is showing the folder-trust dialog; not sending. Its default is \"No, exit\" and its keys are unverified: answer it in the pane (Down, then Enter)"
    exit 1
  fi
  if ! pane_has_permission_dialog "$S:$id" || pane_has_askuser_dialog "$S:$id"; then
    say "$id's screen changed while sending; not sending. Check the pane and retry"
    exit 1
  fi
  if pane_has_pending_paste "$S:$id"; then
    say "$id has an unsent paste in its input box; not sending. Clear it (or press Enter) first"
    exit 1
  fi
  if ! [[ "$msg" =~ ^[[:space:]]*([1-9])[[:space:]]*$ ]]; then
    say "$id is showing a permission dialog; not sending. Answer it with one option number, e.g. \`orch send $id 1\`"
    exit 1
  fi
  type_option "${BASH_REMATCH[1]}" "permission dialog" "no Enter needed; option 3 may switch the worker's permission mode"
fi
[ "$wr" -ne 1 ] || say "(warning: $id looks busy; sending anyway)"
# Issue #179: an unsent paste chip is not a dialog, but our paste + Enter would
# submit the stuck chip together with the new text. Vetoed here rather than in
# is_ready so spawn's send_task and the heartbeat is_ready checks are unchanged.
if pane_has_pending_paste "$S:$id"; then
  say "$id has an unsent paste in its input box; not sending. Clear it (or press Enter) first"
  exit 1
fi
send_prompt "$S:$id" "$msg"
say "sent to $id"
