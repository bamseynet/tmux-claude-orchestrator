#!/usr/bin/env bats
# Hermetic tests for issue #17: hud.sh feeds worker age into the tmux status-bar
# rendering, using `created` (falling back to `updated` for older status files).
# Same hermetic setup as tests/hud.bats: a throwaway copy of hud.sh + lib.sh, no
# tmux window and no `claude` process is ever launched.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"

  HUD_DIR="$BATS_TEST_TMPDIR/hud_copy"
  mkdir -p "$HUD_DIR"
  cp "$BATS_TEST_DIRNAME/../_orch/hud.sh" "$HUD_DIR/"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$HUD_DIR/"
  HUD="$HUD_DIR/hud.sh"
}

mkworker() { # <id> <status> <created-iso>
  jq -n --arg id "$1" --arg s "$2" --arg c "$3" '{id:$id, status:$s, created:$c, updated:$c}' \
    > "$ORCH_ROOT/_orch/state/workers/$1.json"
}

@test "hud.sh includes an age suffix for a worker with a created timestamp" {
  mkworker w1 working "2020-01-01T00:00:00Z"
  run "$HUD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1:working"* ]]
  # years old -> renders in days at minimum
  [[ "$output" =~ w1:working:[0-9]+d ]]
}

@test "hud.sh falls back to 'updated' for age when 'created' is absent" {
  jq -n --arg id w1 --arg s working --arg u "2020-01-01T00:00:00Z" \
    '{id:$id, status:$s, updated:$u}' > "$ORCH_ROOT/_orch/state/workers/w1.json"
  run "$HUD"
  [ "$status" -eq 0 ]
  [[ "$output" =~ w1:working:[0-9]+d ]]
}
