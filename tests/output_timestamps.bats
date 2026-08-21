#!/usr/bin/env bats
# Hermetic tests for issue #90: timestamped terminal output. Exercises lib.sh's
# say()/orch_timestamps_enabled()/orch_timestamp_format() helpers directly
# (default-on, config off, env off, env-beats-config, format selection), then
# a couple of end-to-end checks through `./orch` itself: the human status table
# gets a single invocation-level stamp, and `--json` stays byte-identical.
# No tmux window and no `claude` process is ever launched.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  unset ORCH_TIMESTAMPS ORCH_TIMESTAMP_FORMAT || true
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
}

set_cfg() { # <jq filter>
  jq "$1" "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
}

# --- default on -----------------------------------------------------------------

@test "timestamps are on by default (config untouched)" {
  run orch_timestamps_enabled
  [ "$status" -eq 0 ]
}

@test "say() prefixes a timestamp by default" {
  run say "hello"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ hello$ ]]
}

@test "say() with multiple args joins them on one stamped line" {
  run say "hello" "world"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ hello\ world$ ]]
}

@test "orch_timestamps_enabled defaults on when config.json has no output block" {
  set_cfg 'del(.output)'
  run orch_timestamps_enabled
  [ "$status" -eq 0 ]
}

@test "orch_timestamps_enabled defaults on when config.json is missing entirely" {
  rm -f "$ORCH_ROOT/_orch/config.json"
  run orch_timestamps_enabled
  [ "$status" -eq 0 ]
}

# --- disabled via config ----------------------------------------------------------

@test "output.timestamps=false in config.json disables the prefix" {
  set_cfg '.output.timestamps = false'
  run orch_timestamps_enabled
  [ "$status" -ne 0 ]
}

@test "say() prints bare text when config disables timestamps" {
  set_cfg '.output.timestamps = false'
  run say "plain line"
  [ "$output" = "plain line" ]
}

@test "output.timestamps=true in config.json is explicit-on (no-op vs default)" {
  set_cfg '.output.timestamps = true'
  run orch_timestamps_enabled
  [ "$status" -eq 0 ]
}

# --- disabled via env --------------------------------------------------------------

@test "ORCH_TIMESTAMPS=0 disables regardless of config" {
  export ORCH_TIMESTAMPS=0
  run orch_timestamps_enabled
  [ "$status" -ne 0 ]
}

@test "ORCH_TIMESTAMPS=false disables (word form accepted)" {
  export ORCH_TIMESTAMPS=false
  run orch_timestamps_enabled
  [ "$status" -ne 0 ]
}

@test "ORCH_TIMESTAMPS=1 enables even if config disables" {
  set_cfg '.output.timestamps = false'
  export ORCH_TIMESTAMPS=1
  run orch_timestamps_enabled
  [ "$status" -eq 0 ]
}

# --- env beats config (both directions) --------------------------------------------

@test "env ORCH_TIMESTAMPS=0 beats config.json output.timestamps=true" {
  set_cfg '.output.timestamps = true'
  export ORCH_TIMESTAMPS=0
  run orch_timestamps_enabled
  [ "$status" -ne 0 ]
}

@test "env ORCH_TIMESTAMPS=1 beats config.json output.timestamps=false" {
  set_cfg '.output.timestamps = false'
  export ORCH_TIMESTAMPS=1
  run orch_timestamps_enabled
  [ "$status" -eq 0 ]
}

# --- format selection ---------------------------------------------------------------

@test "default format is full ISO-8601 UTC (matches orch.log)" {
  run orch_timestamp_format
  [ "$output" = "iso" ]
  run say "x"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ x$ ]]
}

@test "output.timestamp_format=short in config.json selects HH:MM:SS" {
  set_cfg '.output.timestamp_format = "short"'
  run say "x"
  [[ "$output" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}\ x$ ]]
}

@test "ORCH_TIMESTAMP_FORMAT=short beats config.json's iso" {
  set_cfg '.output.timestamp_format = "iso"'
  export ORCH_TIMESTAMP_FORMAT=short
  run say "x"
  [[ "$output" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}\ x$ ]]
}

@test "ORCH_TIMESTAMP_FORMAT=iso beats config.json's short" {
  set_cfg '.output.timestamp_format = "short"'
  export ORCH_TIMESTAMP_FORMAT=iso
  run say "x"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

# --- end-to-end via ./orch ----------------------------------------------------------

orch_e2e_setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/toolkit"
  cp -r "$BATS_TEST_DIRNAME/../_orch" "$WORK/toolkit/_orch"
  cp "$BATS_TEST_DIRNAME/../orch" "$WORK/toolkit/orch"
  chmod +x "$WORK/toolkit/orch"
  mkdir -p "$WORK/toolkit/_orch/state/workers"
  ORCH="$WORK/toolkit/orch"
  export ORCH_ROOT="$WORK/toolkit"
}

@test "orch status (human table, default on): exactly one leading timestamp line" {
  orch_e2e_setup
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status
  [ "$status" -eq 0 ]
  stamped="$(printf '%s\n' "$output" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ')"
  [ "$stamped" -eq 1 ]
  [[ "$output" == *"no workers yet"* ]]
}

@test "orch status --json is byte-identical whether timestamps are on or off" {
  orch_e2e_setup
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status --json
  on_output="$output"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 ORCH_TIMESTAMPS=0 "$ORCH" status --json
  [ "$output" = "$on_output" ]
  [ "$output" = "[]" ]
}

@test "orch status disabled via ORCH_TIMESTAMPS=0 has no timestamp line" {
  orch_e2e_setup
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 ORCH_TIMESTAMPS=0 "$ORCH" status
  [ "$status" -eq 0 ]
  stamped="$(printf '%s\n' "$output" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' || true)"
  [ "$stamped" -eq 0 ]
  [ "$output" = "no workers yet" ]
}

@test "orch status disabled via config.json output.timestamps=false has no timestamp line" {
  orch_e2e_setup
  jq '.output.timestamps = false' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status
  [ "$status" -eq 0 ]
  [ "$output" = "no workers yet" ]
}

@test "orch help documents ORCH_TIMESTAMPS/ORCH_TIMESTAMP_FORMAT" {
  orch_e2e_setup
  run "$ORCH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ORCH_TIMESTAMPS"* ]]
  [[ "$output" == *"ORCH_TIMESTAMP_FORMAT"* ]]
}

@test "orch: an error message (target repo does not exist) is timestamped by default" {
  orch_e2e_setup
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO "$ORCH" --repo "$BATS_TEST_TMPDIR/nope-not-here" status
  [ "$status" -ne 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ orch:\ target\ repo\ path\ does\ not\ exist ]]
}

@test "orch: the same error message is bare with ORCH_TIMESTAMPS=0" {
  orch_e2e_setup
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_TIMESTAMPS=0 "$ORCH" --repo "$BATS_TEST_TMPDIR/nope-not-here" status
  [ "$status" -ne 0 ]
  [[ "$output" == "orch: target repo path does not exist:"* ]]
  [[ "$output" != [0-9][0-9][0-9][0-9]-*  ]]
}
