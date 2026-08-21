#!/usr/bin/env bats
# Hermetic tests for issue #51: a task can PASTE into a freshly-spawned worker's
# input box while the follow-up Enter fails to actually submit it — the worker
# then idles at the startup Welcome banner forever with an unsent "[Pasted
# text]" chip, yet spawn.sh's original retry re-pasted the whole task again
# instead of trying the cheap, correct fix: a bare Enter. Re-pasting risks
# duplicating/corrupting an already-landed paste. tmux/git/claude are stubbed;
# no real tmux window, git worktree, or claude process is ever touched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  ENTER_COUNT_FILE="$BATS_TEST_TMPDIR/enter_count"
  READY_AFTER_FILE="$BATS_TEST_TMPDIR/ready_after"  # how many Enters until "ready"
  printf '0' > "$ENTER_COUNT_FILE"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch"
  mkdir -p "$PROJECT_ROOT" "$ORCH_ROOT/_orch"
  cat > "$ORCH_ROOT/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0, "spawn_inject_retries": 2 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON

  # tmux stub: capture-pane shows the Welcome banner until ENTER_COUNT_FILE
  # reaches READY_AFTER_FILE's threshold (simulating the Enter that finally gets
  # through), then shows a plain ready prompt. Every call is logged verbatim so
  # tests can distinguish a bare `send-keys ... Enter` from a full
  # load-buffer/paste-buffer re-inject.
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) exit 0 ;;
  capture-pane)
    n="\$(cat "$ENTER_COUNT_FILE")"
    threshold="\$(cat "$READY_AFTER_FILE" 2>/dev/null || echo 999999)"
    if [ "\$n" -ge "\$threshold" ]; then
      echo '❯ '
    else
      echo 'Welcome to Claude Code'
    fi
    ;;
  send-keys)
    for a in "\$@"; do
      if [ "\$a" = "Enter" ]; then
        n="\$(cat "$ENTER_COUNT_FILE")"
        echo "\$((n + 1))" > "$ENTER_COUNT_FILE"
      fi
    done
    ;;
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
  # attempt) — stub it out so the bounded-retry loops run at test speed instead
  # of costing tens of real seconds per test.
  cat > "$STUBBIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$STUBBIN/tmux" "$STUBBIN/git" "$STUBBIN/claude" "$STUBBIN/sleep"
  PATH="$STUBBIN:$PATH"
}

@test "spawn.sh sends a bare Enter (never re-pastes) when the paste lands but the initial Enter doesn't submit" {
  # Enter #1 launches `claude` itself (tmux send-keys ... Enter for the launch
  # command line); Enter #2 is send_prompt's own trailing Enter after the
  # initial paste — simulate that being the one that gets dropped. The
  # bare-Enter retry (Enter #3) is the one that finally lands.
  printf '3' > "$READY_AFTER_FILE"

  run "$SPAWN" w1 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w1 (sonnet)"* ]]

  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w1.json"
  [ "$output" = "working" ]

  # Exactly one paste (load-buffer/paste-buffer pair) went out — the recovery
  # path must be a bare Enter, not a second full re-paste of the task text.
  paste_calls="$(grep -c 'paste-buffer' "$CALLS")"
  [ "$paste_calls" -eq 1 ]

  # A bare `send-keys ... Enter` (no immediately preceding paste-buffer call for
  # it) was sent as the recovery action.
  grep -Fq 'worker w1: task injection unconfirmed; sending bare Enter' "$ORCH_ROOT/_orch/state/orch.log"
}

@test "spawn.sh marks spawn-failed (never silently 'working') when the banner never clears despite bare-Enter retries" {
  printf '999999' > "$READY_AFTER_FILE"  # never becomes ready

  run "$SPAWN" w2 sonnet "do the thing" --no-worktree
  [[ "$output" == *"spawn-failed w2"* ]]

  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w2.json"
  [ "$output" = "spawn-failed" ]

  # The master is notified via an inbox event — never silently left "working".
  grep -q '"id":"w2"' "$ORCH_ROOT/_orch/state/inbox.jsonl"
  grep -q '"event":"spawn-failed"' "$ORCH_ROOT/_orch/state/inbox.jsonl"

  # Bounded: bare-Enter retries were attempted per the configured cap, not an
  # unbounded loop.
  retries="$(grep -c 'sending bare Enter' "$ORCH_ROOT/_orch/state/orch.log")"
  [ "$retries" -eq 2 ]
}

@test "spawn.sh still confirms normally on the first try when injection lands cleanly (regression guard)" {
  printf '0' > "$READY_AFTER_FILE"  # already ready before any Enter is counted

  run "$SPAWN" w3 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w3 (sonnet)"* ]]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w3.json"
  [ "$output" = "working" ]
  ! grep -q 'sending bare Enter' "$ORCH_ROOT/_orch/state/orch.log" 2>/dev/null
}
