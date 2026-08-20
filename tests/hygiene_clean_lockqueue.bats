#!/usr/bin/env bats
# Hermetic tests for issue #79: `orch clean <id>` must also remove that worker's
# per-id lock file (_worker_lock_file, lib.sh) and any mkdir-fallback ".lock.d"
# directory (#76), and must drop any queued spawn whose `--after` dependency is
# the worker being cleaned (logging what was dropped) while leaving queue entries
# that depend on a DIFFERENT worker untouched.
#
# Same stubbing technique as tests/clean.bats: tmux + git replaced by on-PATH
# stubs, so no real tmux window or git repo is ever touched.

ORCH_DIR="$BATS_TEST_DIRNAME/../_orch"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) ;;   # no matching window -> window-kill branch is a no-op
esac
exit 0
EOF

  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
case "${args[$i]:-}" in
  worktree)
    if [ "${args[$((i+1))]:-}" = "remove" ]; then
      rm -rf "${args[${#args[@]}-1]}"
    fi ;;
  show-ref) exit 1 ;;   # no branch -> skip branch -D
esac
exit 0
EOF

  chmod +x "$STUBBIN/tmux" "$STUBBIN/git"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch"
  mkdir -p "$PROJECT_ROOT" "$ORCH_ROOT/_orch/state/workers"
  STATE_DIR="$ORCH_ROOT/_orch/state"
  QUEUE="$STATE_DIR/queue.jsonl"
}

@test "clean.sh removes the worker's lock file and its mkdir-fallback .lock.d directory" {
  echo '{"id":"w1"}' > "$STATE_DIR/workers/w1.json"
  : > "$STATE_DIR/workers/.w1.lock"
  mkdir -p "$STATE_DIR/workers/.w1.lock.d"
  echo 1234 > "$STATE_DIR/workers/.w1.lock.d/pid"

  run "$ORCH_DIR/clean.sh" w1
  [ "$status" -eq 0 ]
  [ ! -e "$STATE_DIR/workers/.w1.lock" ]
  [ ! -e "$STATE_DIR/workers/.w1.lock.d" ]
}

@test "clean.sh is a no-op (not an error) when no lock file/dir exists" {
  echo '{"id":"w1"}' > "$STATE_DIR/workers/w1.json"
  run "$ORCH_DIR/clean.sh" w1
  [ "$status" -eq 0 ]
}

@test "clean.sh drops a queued spawn whose --after names the cleaned worker, and logs it" {
  echo '{"id":"killed"}' > "$STATE_DIR/workers/killed.json"
  printf '%s\n' '{"id":"verdict","model":"sonnet","task":"t","mode":"","resume":"","allow_csv":"","after":"killed"}' > "$QUEUE"

  run "$ORCH_DIR/clean.sh" killed
  [ "$status" -eq 0 ]
  [[ "$output" == *"dropped 1 queued spawn"* ]]
  [ ! -s "$QUEUE" ]
  grep -q "dropped queued spawn 'verdict'" "$STATE_DIR/orch.log"
}

@test "clean.sh does NOT drop a queued spawn that depends on a DIFFERENT worker (no over-pruning)" {
  echo '{"id":"y"}' > "$STATE_DIR/workers/y.json"
  printf '%s\n' '{"id":"z","model":"sonnet","task":"t","mode":"","resume":"","allow_csv":"","after":"x"}' > "$QUEUE"

  run "$ORCH_DIR/clean.sh" y
  [ "$status" -eq 0 ]
  [ -s "$QUEUE" ]
  run jq -r '.id' "$QUEUE"
  [ "$output" = "z" ]
  run jq -r '.after' "$QUEUE"
  [ "$output" = "x" ]
}

@test "clean.sh leaves dependency-less queue entries alone" {
  echo '{"id":"y"}' > "$STATE_DIR/workers/y.json"
  printf '%s\n' '{"id":"z","model":"sonnet","task":"t","mode":"","resume":"","allow_csv":""}' > "$QUEUE"

  run "$ORCH_DIR/clean.sh" y
  [ "$status" -eq 0 ]
  [ -s "$QUEUE" ]
  run jq -r '.id' "$QUEUE"
  [ "$output" = "z" ]
}

@test "clean.sh only drops the matching entry, preserving order of the rest" {
  echo '{"id":"killed"}' > "$STATE_DIR/workers/killed.json"
  {
    printf '%s\n' '{"id":"a","after":"other"}'
    printf '%s\n' '{"id":"verdict","after":"killed"}'
    printf '%s\n' '{"id":"b"}'
  } > "$QUEUE"

  run "$ORCH_DIR/clean.sh" killed
  [ "$status" -eq 0 ]
  [[ "$output" == *"dropped 1 queued spawn"* ]]
  ids="$(jq -r '.id' "$QUEUE" | tr '\n' ' ')"
  [ "$ids" = "a b " ]
}
