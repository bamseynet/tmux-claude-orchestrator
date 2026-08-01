#!/usr/bin/env bash
# _orch/lib.sh — shared helpers. Source this; do not execute directly.
# Provides: paths, log(), strip_ansi(), pane_tail(), is_busy(), is_ready(),
#           wait_ready(), send_prompt().

# Resolve toolkit root (parent of _orch/) from this file's location.
ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ORCH_DIR="$ORCH_ROOT/_orch"
STATE_DIR="$ORCH_DIR/state"
WORKERS_DIR="$STATE_DIR/workers"
INBOX="$STATE_DIR/inbox.jsonl"
LOG="$STATE_DIR/orch.log"

mkdir -p "$WORKERS_DIR"

: "${SESSION_NAME:=orch}"      # tmux session name
: "${ORCH_WINDOW:=orchestrator}"  # master window name

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# Strip ANSI/OSC/charset escapes. Uses perl (present on macOS by default) because
# BSD sed does not handle \x1b hex escapes reliably.
strip_ansi() {
  perl -pe '
    s/\x1b\[[0-9;:?<=>]*[a-zA-Z]//g;
    s/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)//g;
    s/\x1b[()][0-9A-Za-z]//g;
    s/[\x0e\x0f]//g;
  '
}

# Last N lines of a pane, de-ANSI'd.
pane_tail() { # <target> [lines]
  tmux capture-pane -t "$1" -p 2>/dev/null | tail -n "${2:-15}" | strip_ansi
}

# Busy if Claude Code is mid-turn. The strongest, most version-stable signal is the
# "esc to interrupt" hint it shows while working. TUNE HERE if a future TUI changes it.
is_busy() { # <target>  -> 0 if busy
  pane_tail "$1" 15 | grep -qiE 'esc to interrupt|Running…|Compacting'
}

# Ready if not busy AND the input prompt box is visible.
is_ready() { # <target>  -> 0 if idle & ready for input
  is_busy "$1" && return 1
  pane_tail "$1" 15 | grep -qE '│ >|❯|for shortcuts|Try "'
}

# Block until a pane is ready or timeout. Adds a short settle after ready.
wait_ready() { # <target> [timeout_s]
  local t="${2:-60}" i=0
  while [ "$i" -lt "$t" ]; do
    if is_ready "$1"; then sleep 0.4; return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}

# Deliver text into a pane reliably:
#  - load-buffer/paste-buffer handles multiline (send-keys breaks on newlines)
#  - -p -d pastes bracketed then deletes the buffer
#  - a SEPARATE Enter avoids racing Claude's input buffer
send_prompt() { # <target> <text...>
  local target="$1"; shift
  local text="$*"
  local buf="b-${target//[^a-zA-Z0-9]/_}"
  printf '%s' "$text" | tmux load-buffer -b "$buf" -
  tmux paste-buffer -p -d -b "$buf" -t "$target"
  sleep 0.4
  tmux send-keys -t "$target" Enter
}
