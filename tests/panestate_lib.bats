#!/usr/bin/env bats
# Hermetic tests for pane-state detection hardening (issue #12): the centralized
# TUI match patterns in config.json, and the tightened inject_confirmed logic.
# tmux is replaced with an on-PATH stub whose `capture-pane` output is set per test
# via $PANE_TEXT, so no real tmux window or `claude` process is ever touched.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  printf '' > "$PANE_TEXT_FILE"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  capture-pane) cat "$PANE_TEXT_FILE" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
}

set_pane() { printf '%s\n' "$1" > "$PANE_TEXT_FILE"; }

@test "config.json centralizes the TUI match patterns for is_busy/is_ready/pane_active" {
  run jq -r '.tui_patterns.busy_regex' "$ORCH_ROOT/_orch/config.json"
  [[ "$output" == *"esc to interrupt"* ]]
  run jq -r '.tui_patterns.active_glyph_regex' "$ORCH_ROOT/_orch/config.json"
  [ -n "$output" ]
  run jq -r '.tui_patterns.ready_regex' "$ORCH_ROOT/_orch/config.json"
  [ -n "$output" ]
}

@test "config.json's active_glyph_regex excludes the busy dot (idle false-positive, issue #12)" {
  run jq -r '.tui_patterns.active_glyph_regex' "$ORCH_ROOT/_orch/config.json"
  [[ "$output" != *"●"* ]]
}

@test "pane_active no longer matches a bare busy-dot glyph in otherwise-idle output" {
  set_pane '● Bypassing permissions'
  run pane_active "orch:w1"
  [ "$status" -ne 0 ]
}

@test "pane_active matches a genuine spinner frame" {
  set_pane '✻ Thinking…'
  run pane_active "orch:w1"
  [ "$status" -eq 0 ]
}

@test "pane_active matches the esc-to-interrupt hint" {
  set_pane 'esc to interrupt'
  run pane_active "orch:w1"
  [ "$status" -eq 0 ]
}

@test "inject_confirmed no longer defaults to landed when neither active nor welcome nor ready" {
  # Banner gone, no activity glyph, no ready prompt either -- an ambiguous state
  # that the old code treated as confirmed (issue #12); it must not be now.
  set_pane 'some unrelated transient line'
  run inject_confirmed "orch:w1"
  [ "$status" -ne 0 ]
}

@test "inject_confirmed still confirms when the pane is actively working" {
  set_pane 'esc to interrupt'
  run inject_confirmed "orch:w1"
  [ "$status" -eq 0 ]
}

@test "inject_confirmed still confirms a fast landing: banner gone and back to a ready prompt" {
  set_pane '❯ '
  run inject_confirmed "orch:w1"
  [ "$status" -eq 0 ]
}

@test "inject_confirmed still refuses while the welcome banner is present" {
  set_pane 'Welcome to Claude Code'
  run inject_confirmed "orch:w1"
  [ "$status" -ne 0 ]
}
