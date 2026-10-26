#!/usr/bin/env bats
# shellcheck disable=SC2016
# Issue #182: the rate-limit detector must not match arbitrary pane text or the
# watchdog's own retry nudge. Hermetic: sources watchdog.sh, no tmux/claude.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root" SESSION_NAME="test" ORCH_WINDOW="orchestrator"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
}

@test "the retry nudge does not match the detector (no self-trigger)" {
  [ -n "$WATCHDOG_RL_NUDGE" ]
  run rate_limited "$WATCHDOG_RL_NUDGE"
  [ "$status" -ne 0 ]
}

@test "sweep_window sends exactly WATCHDOG_RL_NUDGE" {
  SENT="$BATS_TEST_TMPDIR/sent"
  # shellcheck disable=SC2317
  send_prompt() { printf '%s' "$2" > "$SENT"; }
  # shellcheck disable=SC2317
  pane_tail() { printf 'back to normal'; }
  # shellcheck disable=SC2317
  wait_ready_or_dialog() { return 0; }
  # shellcheck disable=SC2317
  is_human_managed() { return 1; }
  echo 1065 > "$STATE_DIR/.rl-w1"
  sweep_window w1 65 </dev/null >/dev/null 2>&1 || true
  [ "$(cat "$SENT")" = "$WATCHDOG_RL_NUDGE" ]
}

@test "nudge echoed in the pane does not re-detect on the next tick" {
  [ -n "$WATCHDOG_RL_NUDGE" ]
  echo 1065 > "$STATE_DIR/.rl-w1"
  run rl_action w1 "all good" 1100 65
  [ "$output" = "nudge" ]
  run rl_action w1 "$WATCHDOG_RL_NUDGE" 1115 65
  [ "$status" -eq 1 ]
}

@test "arbitrary text containing the old substrings is not a rate limit" {
  local t
  for t in '+ if grep -qiE "rate limit|429" "$pane"; then' \
           'Merged PR #429 into main; elapsed 4290ms' \
           'refactor: remove overloaded constructor' \
           '@test "rate_limited matches the classic patterns"' \
           "rate limit detected on 'r173'; cooling 65s"; do
    run rate_limited "$t"
    [ "$status" -ne 0 ] || { echo "false positive: $t"; return 1; }
  done
}

@test "captured/assumed real rate-limit lines still match" {
  local n=0 line
  while IFS= read -r line; do
    case "$line" in '#'*|'') continue ;; esac
    run rate_limited "$line"
    [ "$status" -eq 0 ] || { echo "missed: $line"; return 1; }
    n=$((n+1))
  done < "$BATS_TEST_DIRNAME/fixtures/rate_limit_lines.txt"
  [ "$n" -ge 5 ]
}

@test "a real signal among normal output still matches" {
  run rate_limited "$(printf 'doing stuff\n  ⎿  API Error: 429 Too Many Requests\n❯ ')"
  [ "$status" -eq 0 ]
}

@test "config.json and the watchdog.sh fallback share one default regex" {
  local cfg_re fb_re
  cfg_re="$(jq -r '.watchdog.rate_limit_regex' "$BATS_TEST_DIRNAME/../_orch/config.json")"
  fb_re="$(sed -n 's/^rl_regex="\$(jq -r .\.watchdog\.rate_limit_regex \/\/ "\(.*\)". "\$cfg")"$/\1/p' "$BATS_TEST_DIRNAME/../_orch/watchdog.sh")"
  [ -n "$fb_re" ]
  # the fallback sits inside a jq string, so backslashes are doubled there
  fb_re="${fb_re//\\\\/\\}"
  [ "$cfg_re" = "$fb_re" ]
}
