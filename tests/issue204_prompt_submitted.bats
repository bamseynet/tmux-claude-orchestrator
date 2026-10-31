#!/usr/bin/env bats
# Issue #204 (d): a hand-recovered worker keeps `spawn-failed` until its first Stop.
# A UserPromptSubmit hook reports `prompt-submitted`; report.sh moves ONLY
# spawn-failed -> working on it. Positive signal only (no pane scraping, #140).
# Hermetic: ORCH_ROOT is a temp dir; no tmux/claude is launched.

REPORT="$BATS_TEST_DIRNAME/../_orch/report.sh"
LIB="$BATS_TEST_DIRNAME/../_orch/lib.sh"
SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

setup() {
  unset SESSION_NAME
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  W="$ORCH_ROOT/_orch/state/workers"
  mkdir -p "$W"
}

mk() { jq -n --arg s "$2" '{id:"'"$1"'", status:$s, updated:"then"}' > "$W/$1.json"; }

@test "prompt-submitted moves spawn-failed -> working" {
  mk w1 spawn-failed
  run "$REPORT" w1 prompt-submitted
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$W/w1.json")" = "working" ]
}

@test "live_worker_count counts a recovered worker after prompt-submitted" {
  mk w1 spawn-failed
  [ "$(ORCH_ROOT="$ORCH_ROOT" bash -c 'source "'"$LIB"'"; live_worker_count')" -eq 0 ]
  "$REPORT" w1 prompt-submitted
  [ "$(ORCH_ROOT="$ORCH_ROOT" bash -c 'source "'"$LIB"'"; live_worker_count')" -eq 1 ]
}

@test "prompt-submitted leaves every other status unchanged" {
  for st in 'done' needs-input waiting-bg dead merged blocked working spawning subagent-done; do
    mk "x-$st" "$st"
    run "$REPORT" "x-$st" prompt-submitted
    [ "$status" -eq 0 ]
    [ "$(jq -r .status "$W/x-$st.json")" = "$st" ]
    [ "$(jq -r .updated "$W/x-$st.json")" = "then" ]
  done
}

@test "a spawn-failed worker with no hook event stays spawn-failed" {
  mk w1 spawn-failed
  run "$REPORT" w1 subagent-done
  [ "$(jq -r .status "$W/w1.json")" = "spawn-failed" ]
}

@test "prompt-submitted for an unknown worker creates no status file and no inbox noise" {
  run "$REPORT" ghost prompt-submitted
  [ "$status" -eq 0 ]
  [ ! -f "$W/ghost.json" ]
  [ ! -s "$ORCH_ROOT/_orch/state/inbox.jsonl" ]
}

@test "prompt-submitted never wakes the master (no inbox line)" {
  mk w1 spawn-failed
  "$REPORT" w1 prompt-submitted
  [ ! -s "$ORCH_ROOT/_orch/state/inbox.jsonl" ]
}

@test "spawn registers a UserPromptSubmit hook reporting prompt-submitted" {
  STUBBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\ncase "${1:-}" in list-sessions) echo orch;; capture-pane) echo "> ready";; esac\nexit 0\n' > "$STUBBIN/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/fake-git.bash"
  install_fake_git "$STUBBIN"
  chmod +x "$STUBBIN"/*
  PATH="$STUBBIN:$PATH"
  export SESSION_NAME=orch PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT" "$ORCH_ROOT/_orch"
  echo '{"thresholds":{"max_workers":4,"min_free_mb":0,"est_worker_mb":0},"budget":{"enabled":false}}' > "$ORCH_ROOT/_orch/config.json"
  run "$SPAWN" w1 sonnet "t" --no-worktree
  [ "$status" -eq 0 ]
  run jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$ORCH_ROOT/_orch/state/settings/w1.json"
  [[ "$output" == *"report.sh w1 prompt-submitted" ]]
}

@test "reference template mirrors the UserPromptSubmit hook" {
  run jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$BATS_TEST_DIRNAME/../_orch/worker-settings.template.json"
  [[ "$output" == *"report.sh <id> prompt-submitted" ]]
}
