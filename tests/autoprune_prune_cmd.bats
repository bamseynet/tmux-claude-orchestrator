#!/usr/bin/env bats
# Hermetic tests for the explicit `orch prune` command (issue #46): reap every
# terminal (done/spawn-failed) worker on demand, ignoring retention.
#
# `orch` hardcodes ORCH_ROOT to its own toolkit dir (target-repo resolution,
# issue #35), so invoking the real `./orch prune` would mutate this actual
# checkout's _orch/state. Instead, as clean.bats does for `orch clean`, the
# dispatcher wiring is checked statically and the actual reap behaviour is
# exercised by running `_orch/watchdog.sh prune` directly against a throwaway
# ORCH_ROOT/PROJECT_ROOT with tmux + git stubbed on PATH.

ORCH="$BATS_TEST_DIRNAME/../orch"
ORCH_DIR="$BATS_TEST_DIRNAME/../_orch"

@test "orch help documents prune" {
  run "$ORCH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"prune"* ]]
}

@test "orch dispatches prune to _orch/watchdog.sh prune" {
  grep -Eq 'prune\)[[:space:]]*exec .*/_orch/watchdog\.sh.*prune' "$ORCH"
}

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) : ;;
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
  show-ref) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux" "$STUBBIN/git"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch/state/workers" "$PROJECT_ROOT"
}

@test "watchdog.sh prune reaps a terminal worker immediately, regardless of age" {
  echo '{"id":"w1","status":"done","updated":"2020-01-01T00:00:00Z"}' \
    > "$ORCH_ROOT/_orch/state/workers/w1.json"

  run "$ORCH_DIR/watchdog.sh" prune
  [ "$status" -eq 0 ]
  [ ! -e "$ORCH_ROOT/_orch/state/workers/w1.json" ]
}

@test "watchdog.sh prune leaves non-terminal workers alone" {
  echo '{"id":"w2","status":"working","updated":"2020-01-01T00:00:00Z"}' \
    > "$ORCH_ROOT/_orch/state/workers/w2.json"

  run "$ORCH_DIR/watchdog.sh" prune
  [ "$status" -eq 0 ]
  [ -e "$ORCH_ROOT/_orch/state/workers/w2.json" ]
}
