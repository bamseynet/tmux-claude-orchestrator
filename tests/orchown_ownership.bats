#!/usr/bin/env bats
# Hermetic tests for issue #70: `orch attach <id>` marks a worker human-managed
# (an explicit ownership flag, independent of tmux attachment state) so the
# orchestrator/watchdog stop driving it; `orch detach <id>` hands it back.
# `orch status` surfaces a MANAGED column (and --json field), and the watchdog
# skips its rate-limit retry nudge for a human-managed worker.

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/toolkit"
  cp -r "$BATS_TEST_DIRNAME/../_orch" "$WORK/toolkit/_orch"
  cp "$BATS_TEST_DIRNAME/../orch" "$WORK/toolkit/orch"
  chmod +x "$WORK/toolkit/orch"
  mkdir -p "$WORK/toolkit/_orch/state/workers"
  ORCH="$WORK/toolkit/orch"
  WORKERS_DIR="$WORK/toolkit/_orch/state/workers"
  STATE_DIR="$WORK/toolkit/_orch/state"
  export ORCH_ROOT="$WORK/toolkit"
  # Pin the session name. Since #81, lib.sh defaults it to "orch-<hash of
  # ORCH_ROOT>", which is a fresh temp dir on every run -- so any assertion
  # naming the session has to fix it here rather than assume the bare "orch".
  export SESSION_NAME="orch"

  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
}

mkworker() { # <id> <status>
  jq -n --arg id "$1" --arg s "$2" '{id:$id, status:$s, model:"sonnet", task:"t"}' \
    > "$WORKERS_DIR/$1.json"
}

stub_tmux_with_window() {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) printf '%s\n' orchestrator w1 ;;
  attach) echo "ATTACHED:$*" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
}

run_orch() { # env safety, same as status_table.bats
  env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$@"
}

# --- lib.sh helpers -----------------------------------------------------------

@test "lib.sh: is_human_managed is false until mark_human_managed is called" {
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/lib.sh"
  run is_human_managed w1
  [ "$status" -ne 0 ]
  mark_human_managed w1
  run is_human_managed w1
  [ "$status" -eq 0 ]
}

@test "lib.sh: clear_human_managed hands the worker back" {
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/lib.sh"
  mark_human_managed w1
  is_human_managed w1
  clear_human_managed w1
  run is_human_managed w1
  [ "$status" -ne 0 ]
}

@test "lib.sh: ownership flag is per-worker" {
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/lib.sh"
  mark_human_managed w1
  run is_human_managed w2
  [ "$status" -ne 0 ]
}

# --- orch attach / detach ------------------------------------------------------

@test "orch attach <id> marks the worker human-managed before attaching" {
  stub_tmux_with_window
  PATH="$STUBBIN:$PATH" run "$ORCH" attach w1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ATTACHED:attach -t orch:w1"* ]]
  [ -f "$STATE_DIR/.manual-w1" ]
}

@test "orch attach with no id does not mark anything human-managed" {
  stub_tmux_with_window
  PATH="$STUBBIN:$PATH" run "$ORCH" attach
  [ "$status" -eq 0 ]
  shopt -s nullglob
  markers=("$STATE_DIR"/.manual-*)
  [ "${#markers[@]}" -eq 0 ]
}

@test "orch detach <id> clears the flag and emits a 'detached' event" {
  stub_tmux_with_window
  PATH="$STUBBIN:$PATH" run "$ORCH" attach w1
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.manual-w1" ]

  run "$ORCH" detach w1
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_DIR/.manual-w1" ]

  run cat "$STATE_DIR/inbox.jsonl"
  [[ "$output" == *'"id":"w1"'* ]]
  [[ "$output" == *'"event":"detached"'* ]]

  run cat "$STATE_DIR/events.jsonl"
  [[ "$output" == *'"id":"w1"'* ]]
  [[ "$output" == *'"event":"detached"'* ]]
}

@test "orch detach on a never-attached worker is a harmless no-op" {
  run "$ORCH" detach w1
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_DIR/.manual-w1" ]
}

@test "orch detach requires an id" {
  run "$ORCH" detach
  [ "$status" -ne 0 ]
}

# --- orch status ----------------------------------------------------------------

@test "orch status table shows a MANAGED column defaulting to 'orch'" {
  mkworker w1 working
  run run_orch "$ORCH" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"MANAGED"* ]]
  line="$(printf '%s\n' "$output" | grep w1)"
  [[ "$line" == *"orch"* ]]
}

@test "orch status table shows 'human' for an attached worker" {
  mkworker w1 working
  : > "$STATE_DIR/.manual-w1"
  run run_orch "$ORCH" status
  [ "$status" -eq 0 ]
  line="$(printf '%s\n' "$output" | grep w1)"
  [[ "$line" == *"human"* ]]
}

@test "orch status --json includes the managed field" {
  mkworker w1 working
  run run_orch "$ORCH" status --json
  [ "$status" -eq 0 ]
  run jq -r '.[0].managed' <<<"$output"
  [ "$output" = "orch" ]
}

@test "orch status --json reports 'human' once attached" {
  mkworker w1 working
  : > "$STATE_DIR/.manual-w1"
  run run_orch "$ORCH" status --json
  [ "$status" -eq 0 ]
  run jq -r '.[0].managed' <<<"$output"
  [ "$output" = "human" ]
}

# --- watchdog: skip rate-limit nudges for human-managed workers -----------------

@test "watchdog sweep_window skips the retry nudge for a human-managed worker" {
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/lib.sh"
  mark_human_managed w1
  export SESSION_NAME="test"
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/watchdog.sh"
  # shellcheck disable=SC2317  # invoked indirectly via sweep_window
  pane_tail() { printf '%s' "back to normal, ready for input"; }
  # shellcheck disable=SC2317
  send_prompt() { echo "SEND_PROMPT_CALLED:$*" >> "$BATS_TEST_TMPDIR/sent.log"; }

  echo 1065 > "$STATE_DIR/.rl-w1"
  sweep_window w1 65 </dev/null >/dev/null 2>&1 || true
  # rl_action runs with the real clock inside sweep_window, so force it via a
  # cooldown timestamp far in the past instead of controlling `now` directly.
  [ ! -f "$BATS_TEST_TMPDIR/sent.log" ]
  grep -q "human-managed" "$LOG"
}

@test "watchdog sweep_window still nudges a non-managed worker" {
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/lib.sh"
  export SESSION_NAME="test"
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/watchdog.sh"
  # shellcheck disable=SC2317
  pane_tail() { printf '%s' "back to normal, ready for input"; }
  # shellcheck disable=SC2317
  send_prompt() { echo "SEND_PROMPT_CALLED:$*" >> "$BATS_TEST_TMPDIR/sent.log"; }
  # shellcheck disable=SC2317
  wait_ready() { return 0; }

  echo 1065 > "$STATE_DIR/.rl-w1"
  sweep_window w1 65 </dev/null >/dev/null 2>&1 || true
  [ -f "$BATS_TEST_TMPDIR/sent.log" ]
  grep -q "SEND_PROMPT_CALLED" "$BATS_TEST_TMPDIR/sent.log"
}
