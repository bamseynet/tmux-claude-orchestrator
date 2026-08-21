#!/usr/bin/env bats
# Hermetic tests for single-worker teardown: `orch clean|kill <id>` (issue #16).
# The dispatcher/help tests read static sources and the help banner only.
# The behavioural test runs _orch/clean.sh against a throwaway ORCH_ROOT /
# PROJECT_ROOT with tmux + git replaced by on-PATH stubs, so it launches no real
# tmux window and mutates no real git repo — fully offline in CI.

ORCH="$BATS_TEST_DIRNAME/../orch"
ORCH_DIR="$BATS_TEST_DIRNAME/../_orch"

# --- dispatcher + help wiring (static / banner) ---------------------------------

@test "orch help documents clean and kill" {
  run "$ORCH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [[ "$output" == *"kill"* ]]
}

@test "orch dispatches clean and kill to _orch/clean.sh" {
  grep -Eq 'clean\|kill\)[[:space:]]*exec .*/_orch/clean\.sh' "$ORCH"
}

@test "clean.sh exists and is executable" {
  [ -x "$ORCH_DIR/clean.sh" ]
}

# --- artifact coverage (static): every leaked artifact is addressed ------------

@test "clean.sh removes the tmux window" {
  grep -Eq 'kill-window' "$ORCH_DIR/clean.sh"
}

@test "clean.sh force-removes the git worktree" {
  grep -Eq 'worktree remove --force' "$ORCH_DIR/clean.sh"
}

@test "clean.sh deletes the namespaced orch/<hash>/<id> branch (issue #86)" {
  grep -Fq 'branch="$(worker_branch "$id")"' "$ORCH_DIR/clean.sh"
  grep -Eq 'branch -D "\$branch"' "$ORCH_DIR/clean.sh"
}

@test "clean.sh removes the status file and watchdog scratch" {
  grep -Fq 'rm -f "$WORKERS_DIR/$id.json"' "$ORCH_DIR/clean.sh"
  grep -Fq 'rm -f "$STATE_DIR/.wd-$id"' "$ORCH_DIR/clean.sh"
}

# --- behavioural: idempotent teardown with stubbed tmux + git ------------------

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  # tmux stub: report the worker window as present so the kill-window branch runs,
  # but perform nothing.
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) echo "w1" ;;   # matches the id we clean below
esac
exit 0
EOF

  # git stub: `worktree remove` actually deletes the target dir (mimicking real
  # git); everything else is a graceful no-op. show-ref reports the branch present
  # so the branch-delete branch is exercised.
  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
case "${args[$i]:-}" in
  worktree)
    if [ "${args[$((i+1))]:-}" = "remove" ]; then
      rm -rf "${args[${#args[@]}-1]}"
    fi ;;
  show-ref) exit 0 ;;   # branch present -> exercise branch -D
esac
exit 0
EOF

  chmod +x "$STUBBIN/tmux" "$STUBBIN/git"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch"
  mkdir -p "$PROJECT_ROOT"
}

@test "clean.sh tears down every artifact and is idempotent" {
  # Seed the artifacts a worker 'w1' would leave behind. Worktree path/branch
  # are namespaced per ORCH_ROOT (issue #86); ask lib.sh for the real path
  # instead of assuming the old bare "../wt/<id>" layout.
  wdir="$(ORCH_ROOT="$ORCH_ROOT" bash -c 'source "'"$ORCH_DIR"'/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  echo '{"id":"w1"}' > "$ORCH_ROOT/_orch/state/workers/w1.json"
  echo x > "$ORCH_ROOT/_orch/state/.wd-w1"
  mkdir -p "$wdir"

  run "$ORCH_DIR/clean.sh" w1
  [ "$status" -eq 0 ]
  [ ! -e "$ORCH_ROOT/_orch/state/workers/w1.json" ]
  [ ! -e "$ORCH_ROOT/_orch/state/.wd-w1" ]
  [ ! -d "$wdir" ]

  # Second run against an already-clean id must still succeed (idempotent).
  run "$ORCH_DIR/clean.sh" w1
  [ "$status" -eq 0 ]
}

@test "clean.sh requires an id argument" {
  run "$ORCH_DIR/clean.sh"
  [ "$status" -ne 0 ]
}

# --- prefix-hijack regression (issue #107) ----------------------------------
# Real tmux's target resolution matches an unambiguous PREFIX (confirmed
# against tmux 3.4), not just an exact name. clean.sh's kill-window is the
# highest-stakes write path in the whole toolkit: it runs UNATTENDED from
# `orch prune` and the watchdog's dead-worker sweep, with no operator in the
# loop, so a bare `-t "$S"`/`-t "$S:$id"` here could silently KILL a window in
# a DIFFERENT, longer-named live session instead of correctly no-op'ing
# (clean.sh is documented as idempotent: a missing session is a no-op, not an
# error). Only "billing" is actually live and holds window "w1"; this
# install's own session ("bill") is NOT running. Assert the real hijack
# signal -- no kill-window call ever reaches "billing" -- not a status-code
# proxy for it, and that clean.sh still exits 0 (idempotent no-op) rather than
# erroring.
@test "clean.sh refuses to kill a window in a DIFFERENT live session whose name is a prefix of the target (issue #107)" {
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "billing" ;;
  list-windows) echo "w1" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  SESSION_NAME="bill" run "$ORCH_DIR/clean.sh" w1
  [ "$status" -eq 0 ]
  ! grep -q '^kill-window' "$CALLS"
}
