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
  opt="${BASH_REMATCH[1]}"
  # The selector silently ignores a digit with no matching row; reporting it as
  # typed would leave the caller believing a still-blocked worker was answered.
  # Only the cursor row's own option block counts (from the last blank row above
  # the cursor down): numbered prose or a submitted "1. ..." prompt higher up in
  # the tail would otherwise vouch for a digit the selector ignores.
  if ! pane_tail "$S:$id" 25 | OPT="$opt" CUR="$TUI_ASKUSER_CHOICE_REGEX" awk '
      { r[NR] = $0 } $0 ~ ENVIRON["CUR"] { c = NR }
      END {
        if (!c) exit 1
        s = 0; for (i = 1; i < c; i++) if (r[i] !~ /[^[:space:]]/) s = i
        for (i = s + 1; i <= NR; i++) if (r[i] ~ ("^[[:space:]│❯]*" ENVIRON["OPT"] "\\.")) exit 0
        exit 1
      }'; then
    say "$id's question selector shows no option $opt; not sending. Check the pane for the option numbers"
    exit 1
  fi
  tmux send-keys -t "$S:$id" -l "$opt"
  say "typed option $opt into $id's question selector (a multi-select question only toggles it; check the pane)"
  exit 0
fi
# The selector check above re-captures the pane; if it failed only because the
# pane changed in between, the numeric paste below could still land on a
# selector (whose paste+Enter picks the highlighted option). Paste a number only
# onto a dialog this capture still shows.
if [ "$wr" -eq 2 ] && ! pane_has_dialog "$S:$id"; then
  say "$id's screen changed while sending; not sending. Check the pane and retry"
  exit 1
fi
if [ "$wr" -eq 2 ] && ! [[ "$msg" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
  say "$id is showing a dialog (not ready); not sending. Answer it with a number, e.g. \`orch send $id 1\`"
  exit 1
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
