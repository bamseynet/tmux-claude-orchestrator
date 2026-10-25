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
  # tui_patterns come from the SHIPPED config, so these tests exercise the
  # regexes that actually ship rather than a private copy that can drift.
  jq '{
    thresholds: { max_workers: 4, min_free_mb: 0, est_worker_mb: 0, spawn_inject_retries: 2 },
    budget: { enabled: false, max_usd: 5.0, est_usd_per_worker: 0.5 },
    tui_patterns: .tui_patterns
  }' "$BATS_TEST_DIRNAME/../_orch/config.json" > "$ORCH_ROOT/_orch/config.json"

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

@test "spawn.sh sends the task itself once a pre-injection dialog clears, and never confirms an unsent task" {
  # The trust dialog is up when the first injection is attempted (so it is
  # skipped), then clears to a plain ready prompt with no startup banner. A
  # ready prompt must NOT confirm a task that was never sent, and the ladder
  # must paste the task rather than press a bare Enter into an empty box.
  cat > "$PANE_FILE" <<'EOF'
 Quick safety check: Is this a project you created or one you trust? ...
❯ No, exit
  Yes, I trust this folder
EOF
  COUNT_FILE="$BATS_TEST_TMPDIR/captures"
  echo 0 > "$COUNT_FILE"
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) exit 0 ;;
  capture-pane)
    n=\$(( \$(cat "$COUNT_FILE") + 1 )); echo "\$n" > "$COUNT_FILE"
    [ "\$n" -gt 5 ] && echo '❯ ' > "$PANE_FILE"
    cat "$PANE_FILE" 2>/dev/null ;;
  show-buffer) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  run "$SPAWN" w4 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w4 (sonnet)"* ]]

  paste_calls="$(grep -c 'paste-buffer' "$CALLS" || true)"
  [ "$paste_calls" -eq 1 ]
  # Exactly one Enter: send_prompt's own trailing Enter for that one paste --
  # no bare-Enter retry into the empty input box.
  [ "$(bare_enter_count)" -eq 1 ]
  grep -Fq 'worker w4: dialog on screen before first injection attempt; not sending' "$ORCH_ROOT/_orch/state/orch.log"
  grep -Fq 'worker w4: dialog cleared; sending the task' "$ORCH_ROOT/_orch/state/orch.log"
}

@test "a late-clearing dialog does not eat the bare-Enter retry the just-sent task needs" {
  # The trust dialog outlasts the first retry, so the task is first sent on the
  # LAST retry. Its trailing Enter is lost (the #51 shape: chip left unsent).
  # The bare-Enter rung must still be available for that paste instead of the
  # ladder dropping straight to spawn-failed on the unsent chip.
  cat > "$PANE_FILE" <<'EOF2'
 Quick safety check: Is this a project you created or one you trust? ...
❯ No, exit
  Yes, I trust this folder
EOF2
  COUNT_FILE="$BATS_TEST_TMPDIR/captures"; echo 0 > "$COUNT_FILE"
  ENTER_FILE="$BATS_TEST_TMPDIR/enters"; echo 0 > "$ENTER_FILE"
  cat > "$STUBBIN/tmux" <<EOF2
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) exit 0 ;;
  capture-pane)
    n=\$(( \$(cat "$COUNT_FILE") + 1 )); echo "\$n" > "$COUNT_FILE"
    if [ "\$n" -eq 23 ]; then
      printf '%s\n' '✻ Welcome to Claude Code!' '╭────────────────────────────────╮' '│ ❯ [Pasted text #1 +31 lines]   │' '╰────────────────────────────────╯' > "$PANE_FILE"
    fi
    cat "$PANE_FILE" 2>/dev/null ;;
  send-keys)
    if [ "\$#" -eq 4 ] && [ "\$4" = "Enter" ]; then
      e=\$(( \$(cat "$ENTER_FILE") + 1 )); echo "\$e" > "$ENTER_FILE"
      [ "\$e" -ge 2 ] && echo 'esc to interrupt' > "$PANE_FILE"
    fi ;;
  show-buffer) exit 1 ;;
esac
exit 0
EOF2
  chmod +x "$STUBBIN/tmux"

  run "$SPAWN" w5 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w5 (sonnet)"* ]]
  paste_calls="$(grep -c 'paste-buffer' "$CALLS" || true)"
  [ "$paste_calls" -eq 1 ]
  grep -Fq 'worker w5: dialog cleared; sending the task' "$ORCH_ROOT/_orch/state/orch.log"
  grep -Fq 'worker w5: task injection unconfirmed; sending bare Enter' "$ORCH_ROOT/_orch/state/orch.log"
}

@test "a hook status written while a dialog holds back the first send does not count as spawned" {
  # The trust dialog never clears, but a Notification hook writes needs-input
  # (e.g. for the dialog itself). The task never went out, so this must still
  # end spawn-failed with zero pastes -- not a "spawned" worker with no task.
  cat > "$PANE_FILE" <<'EOF2'
 Quick safety check: Is this a project you created or one you trust? ...
❯ No, exit
  Yes, I trust this folder
EOF2
  WJ="$ORCH_ROOT/_orch/state/workers/w6.json"
  LOGF="$ORCH_ROOT/_orch/state/orch.log"
  cat > "$STUBBIN/tmux" <<EOF2
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) exit 0 ;;
  capture-pane)
    if grep -q 'not sending' "$LOGF" 2>/dev/null && [ -f "$WJ" ]; then
      jq '.status = "needs-input"' "$WJ" > "$WJ.t" && mv "$WJ.t" "$WJ"
    fi
    cat "$PANE_FILE" 2>/dev/null ;;
  show-buffer) exit 1 ;;
esac
exit 0
EOF2
  chmod +x "$STUBBIN/tmux"

  run "$SPAWN" w6 sonnet "do the thing" --no-worktree
  [[ "$output" == *"spawn-failed w6"* ]]
  run jq -r .status "$WJ"
  [ "$output" = "spawn-failed" ]
  paste_calls="$(grep -c 'paste-buffer' "$CALLS" || true)"
  [ "$paste_calls" -eq 0 ]
}

@test "a first send made by the last resort still gets one bare-Enter follow-up" {
  # No retry rungs: the dialog clears during the initial wait, so the last
  # resort makes the FIRST send. Its trailing Enter is lost (chip left unsent);
  # one bare Enter must follow instead of dropping straight to spawn-failed.
  jq '.thresholds.spawn_inject_retries = 0' "$ORCH_ROOT/_orch/config.json" > "$BATS_TEST_TMPDIR/c.json"
  mv "$BATS_TEST_TMPDIR/c.json" "$ORCH_ROOT/_orch/config.json"
  cat > "$PANE_FILE" <<'EOF2'
 Quick safety check: Is this a project you created or one you trust? ...
❯ No, exit
  Yes, I trust this folder
EOF2
  LOGF="$ORCH_ROOT/_orch/state/orch.log"
  CLEARED="$BATS_TEST_TMPDIR/cleared"
  cat > "$STUBBIN/tmux" <<EOF2
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) exit 0 ;;
  capture-pane)
    if [ ! -f "$CLEARED" ] && grep -q 'not sending' "$LOGF" 2>/dev/null; then
      touch "$CLEARED"; echo '❯ ' > "$PANE_FILE"
    fi
    cat "$PANE_FILE" 2>/dev/null ;;
  paste-buffer)
    printf '%s\n' '✻ Welcome to Claude Code!' '╭────────────────────────────────╮' '│ ❯ [Pasted text #1 +31 lines]   │' '╰────────────────────────────────╯' > "$PANE_FILE" ;;
  send-keys)
    if [ "\$#" -eq 4 ] && [ "\$4" = "Enter" ] && grep -q 'first send unconfirmed' "$LOGF" 2>/dev/null; then
      echo 'esc to interrupt' > "$PANE_FILE"
    fi ;;
  show-buffer) exit 1 ;;
esac
exit 0
EOF2
  chmod +x "$STUBBIN/tmux"

  run "$SPAWN" w7 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w7 (sonnet)"* ]]
  paste_calls="$(grep -c 'paste-buffer' "$CALLS" || true)"
  [ "$paste_calls" -eq 1 ]
  grep -Fq 'worker w7: dialog cleared after the last retry; sending the task once' "$LOGF"
  grep -Fq 'worker w7: first send unconfirmed; sending one bare Enter' "$LOGF"
}
