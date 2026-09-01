#!/usr/bin/env bats
# Hermetic integration tests for issues #132/#133: spawn.sh's #51 bare-Enter
# ladder must never send Enter (bare, or as the trailing keystroke of a
# paste) into a pane showing a dialog, and the last-resort re-paste must not
# fire when the pane still holds an un-submitted paste chip OR a dialog.
# tmux/git/claude are stubbed; no real tmux window, git worktree, or claude
# process is ever touched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"
# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  PANE_FILE="$BATS_TEST_TMPDIR/pane.txt"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch"
  mkdir -p "$PROJECT_ROOT" "$ORCH_ROOT/_orch"
  cat > "$ORCH_ROOT/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0, "spawn_inject_retries": 2 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 },
  "tui_patterns": {
    "permission_dialog_regex": "Do you want to proceed\\?",
    "trust_dialog_regex": "trust this folder|created or one you trust"
  }
}
JSON

  # tmux stub: capture-pane always echoes whatever is currently in PANE_FILE,
  # so each test drives the exact pane shape it wants. Every call is logged
  # verbatim so tests can assert on exactly what was (or wasn't) sent.
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) exit 0 ;;
  capture-pane) cat "$PANE_FILE" 2>/dev/null ;;
  show-buffer) exit 1 ;;
esac
exit 0
EOF

  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
if [ "${args[$i]:-}" = "worktree" ] && [ "${args[$((i+1))]:-}" = "add" ]; then
  mkdir -p "${args[$((${#args[@]}-1))]}"
fi
exit 0
EOF

  cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  # confirm_inject/wait_ready poll with real `sleep` calls (up to 15s per
  # attempt) — stub it out so the bounded-retry loops run at test speed.
  cat > "$STUBBIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$STUBBIN/tmux" "$STUBBIN/git" "$STUBBIN/claude" "$STUBBIN/sleep"
  PATH="$STUBBIN:$PATH"
}

# A bare `send-keys -t <target> Enter` call, i.e. exactly the one that would be
# consumed by a dialog as "select the highlighted choice" -- distinct from the
# launch line's `send-keys ... claude ... Enter` and from a paste-buffer's own
# trailing Enter.
bare_enter_count() {
  grep -cE '^send-keys -t [^ ]+ Enter$' "$CALLS" || true
}

@test "spawn.sh never sends a bare Enter into the folder-trust dialog and ends spawn-failed (issue #133 production repro)" {
  cat > "$PANE_FILE" <<'EOF'
 Quick safety check: Is this a project you created or one you trust? ...
 Claude Code'll be able to read, edit, and execute files here.
 Security guide
❯ No, exit
  Yes, I trust this folder
 Enter to confirm · Esc to cancel
EOF

  run "$SPAWN" w1 sonnet "do the thing" --no-worktree
  [[ "$output" == *"spawn-failed w1"* ]]

  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w1.json"
  [ "$output" = "spawn-failed" ]

  [ "$(bare_enter_count)" -eq 0 ]
  paste_calls="$(grep -c 'paste-buffer' "$CALLS" || true)"
  [ "$paste_calls" -eq 0 ]

  grep -Fq 'worker w1: dialog on screen before first injection attempt; not sending' "$ORCH_ROOT/_orch/state/orch.log"
  grep -Fq 'worker w1: dialog on screen; not re-pasting' "$ORCH_ROOT/_orch/state/orch.log"
  refute_grep_in_existing 'sending bare Enter' "$ORCH_ROOT/_orch/state/orch.log"
}

@test "spawn.sh never sends a bare Enter into a permission dialog and treats it as confirmed (issue #133 healthy-worker case)" {
  # Pane starts at the plain startup banner (no dialog yet) so the initial
  # send_prompt goes through normally; only AFTER that paste lands does the
  # pane switch to the #133 shape (banner still in the 25-row capture, worker
  # now blocked on a permission dialog for its first tool call). A permission
  # dialog appearing before anything was ever sent is not a reachable Claude
  # Code state, so this ordering is what actually reproduces the issue.
  cat > "$PANE_FILE" <<'EOF'
✻ Welcome to Claude Code!
EOF
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) exit 0 ;;
  capture-pane) cat "$PANE_FILE" 2>/dev/null ;;
  paste-buffer)
    cat > "$PANE_FILE" <<'PANE'
✻ Welcome to Claude Code!

Do you want to proceed?
 1. Yes
 2. No
PANE
    ;;
  show-buffer) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  run "$SPAWN" w2 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w2 (sonnet)"* ]]

  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w2.json"
  [ "$output" = "working" ]

  # The permission-dialog-as-positive-evidence check confirms on the very
  # first poll, so the retry ladder (bare-Enter or otherwise) is never
  # entered at all -- neither log line appears.
  refute_grep_in_existing 'sending bare Enter\|refusing bare Enter' "$ORCH_ROOT/_orch/state/orch.log"

  # Exactly one paste went out (the initial injection), confirmed on the very
  # first poll once the dialog appears -- the retry ladder is never entered.
  paste_calls="$(grep -c 'paste-buffer' "$CALLS")"
  [ "$paste_calls" -eq 1 ]
}

@test "spawn.sh does not re-paste while an unsent [Pasted text] chip is still in the input box (issue #132)" {
  cat > "$PANE_FILE" <<'EOF'
✻ Welcome to Claude Code!
╭────────────────────────────────╮
│ ❯ [Pasted text #1 +31 lines]   │
╰────────────────────────────────╯
  Sonnet 5  energy
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF

  run "$SPAWN" w3 sonnet "do the thing" --no-worktree
  [[ "$output" == *"spawn-failed w3"* ]]

  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w3.json"
  [ "$output" = "spawn-failed" ]

  paste_calls="$(grep -c 'paste-buffer' "$CALLS")"
  [ "$paste_calls" -eq 1 ]
  grep -Fq 'worker w3: task text still sits unsent in the input box; not re-pasting' "$ORCH_ROOT/_orch/state/orch.log"
}
