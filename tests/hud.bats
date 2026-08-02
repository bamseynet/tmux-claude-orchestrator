#!/usr/bin/env bats
# Hermetic tests for _orch/hud.sh's status-color map and budget line.
#
# hud.sh resolves its own config.json relative to its script location (not via
# ORCH_ROOT), so we run it from a temp copy alongside lib.sh, with a controlled
# config.json next to it. ORCH_ROOT is redirected separately for WORKERS_DIR/
# SPEND_FILE (lib.sh's CONFIG, used inside est_spend_usd, follows ORCH_ROOT too,
# so a matching config.json is written there as well). No tmux window and no
# `claude` process is ever launched.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"

  HUD_DIR="$BATS_TEST_TMPDIR/hud_copy"
  mkdir -p "$HUD_DIR"
  cp "$BATS_TEST_DIRNAME/../_orch/hud.sh" "$HUD_DIR/"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$HUD_DIR/"
  HUD="$HUD_DIR/hud.sh"
}

mkworker() { # <id> <status>
  jq -n --arg id "$1" --arg s "$2" '{id:$id, status:$s}' > "$ORCH_ROOT/_orch/state/workers/$1.json"
}

@test "hud.sh maps blocked/needs-input/error to bold red" {
  mkworker w1 blocked
  mkworker w2 needs-input
  mkworker w3 error
  run "$HUD"
  [ "$status" -eq 0 ]
  [[ "$output" == *'#[fg=red,bold]w1:blocked#[default]'* ]]
  [[ "$output" == *'#[fg=red,bold]w2:needs-input#[default]'* ]]
  [[ "$output" == *'#[fg=red,bold]w3:error#[default]'* ]]
}

@test "hud.sh maps done/subagent-done to green" {
  mkworker w1 done
  mkworker w2 subagent-done
  run "$HUD"
  [[ "$output" == *'#[fg=green]w1:done#[default]'* ]]
  [[ "$output" == *'#[fg=green]w2:subagent-done#[default]'* ]]
}

@test "hud.sh maps working/spawning to yellow and queued to cyan" {
  mkworker w1 working
  mkworker w2 spawning
  mkworker w3 queued
  run "$HUD"
  [[ "$output" == *'#[fg=yellow]w1:working#[default]'* ]]
  [[ "$output" == *'#[fg=yellow]w2:spawning#[default]'* ]]
  [[ "$output" == *'#[fg=cyan]w3:queued#[default]'* ]]
}

@test "hud.sh falls back to white for an unrecognized status" {
  mkworker w1 something-else
  run "$HUD"
  [[ "$output" == *'#[fg=white]w1:something-else#[default]'* ]]
}

@test "hud.sh falls back to 'no workers' when none exist" {
  run "$HUD"
  [ "$status" -eq 0 ]
  [[ "$output" == *'no workers'* ]]
}

@test "hud.sh omits the spend line when config.json has no budget.max_usd" {
  echo '{}' > "$HUD_DIR/config.json"
  mkworker w1 working
  run "$HUD"
  [[ "$output" != *'~$'* ]]
}

@test "hud.sh shows the coarse spend estimate against budget.max_usd when configured" {
  cat > "$HUD_DIR/config.json" <<'JSON'
{"budget":{"max_usd":5.0,"est_usd_per_worker":0.5}}
JSON
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$HUD_DIR/config.json" "$ORCH_ROOT/_orch/config.json"
  jq -n '{spawns:2}' > "$ORCH_ROOT/_orch/state/spend.json"
  mkworker w1 working
  run "$HUD"
  [[ "$output" == *'~$1.00/$5'* ]]
}
