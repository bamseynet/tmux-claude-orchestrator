#!/usr/bin/env bats
# Hermetic tests for pane_has_draft() in _orch/lib.sh (issue #38): a heartbeat
# injection must be able to tell an empty idle input line apart from one holding
# the operator's unsent draft. tmux is stubbed so no real tmux window is touched.

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

@test "pane_has_draft is false on an empty idle prompt" {
  set_pane '❯ '
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is false on the placeholder hint text" {
  set_pane '❯ Try "edit <file>" to change things'
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is true when operator text follows the prompt glyph" {
  set_pane '❯ can you also check the'
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft is true with the box-drawing input glyph variant" {
  set_pane '│ > half-typed instructio'
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}
