#!/usr/bin/env bats
# Hermetic tests for issue #20: `orch attach <id>`, help text alignment with the
# real verb set, and the shared check_deps() dependency guard. tmux is replaced
# with an on-PATH stub, so no real tmux session/window is ever touched.

ORCH="$BATS_TEST_DIRNAME/../orch"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  export ORCH_ROOT="$BATS_TEST_DIRNAME/.."
  export SESSION_NAME="orch"
}

stub_tmux_with_window() {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' orchestrator w1 ;;
  attach) echo "ATTACHED:$*" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
}

@test "orch attach with no id attaches to the whole session" {
  stub_tmux_with_window
  PATH="$STUBBIN:$PATH" run "$ORCH" attach
  [ "$status" -eq 0 ]
  [[ "$output" == *"ATTACHED:attach -t orch"* ]]
}

@test "orch attach <id> attaches directly to that worker's window" {
  stub_tmux_with_window
  PATH="$STUBBIN:$PATH" run "$ORCH" attach w1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ATTACHED:attach -t orch:w1"* ]]
}

@test "orch attach <id> fails clearly when the worker window does not exist" {
  stub_tmux_with_window
  PATH="$STUBBIN:$PATH" run "$ORCH" attach nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"no worker window 'nope' in session 'orch'"* ]]
}

@test "help text lists the real verb set, including previously-omitted verbs" {
  run "$ORCH" help
  [ "$status" -eq 0 ]
  for verb in "orch attach" "orch hud" "orch prune" "orch logs" "orch events" "orch collect" "orch send" "orch clean" "orch kill" "orch status"; do
    [[ "$output" == *"$verb"* ]]
  done
  [[ "$output" == *"alias: bootstrap"* ]]
  [[ "$output" == *"alias: stop"* ]]
}

@test "check_deps reports success when all deps are on PATH" {
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/lib.sh"
  run check_deps sh
  [ "$status" -eq 0 ]
}

@test "check_deps reports a clear failure for a missing dependency" {
  # shellcheck disable=SC1091
  source "$ORCH_ROOT/_orch/lib.sh"
  run check_deps definitely-not-a-real-binary
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing dependency: definitely-not-a-real-binary"* ]]
}

@test "orch entrypoint calls check_deps before target-repo resolution" {
  grep -q '^check_deps tmux jq claude perl git$' "$ORCH_ROOT/orch"
}
