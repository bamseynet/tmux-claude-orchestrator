#!/usr/bin/env bats
# Hermetic tests for issue #90: timestamped terminal output. Exercises lib.sh's
# say()/orch_timestamps_enabled()/orch_timestamp_format() helpers directly
# (default-on, config off, env off, env-beats-config, format selection), then
# a couple of end-to-end checks through `./orch` itself: the human status table
# gets a single invocation-level stamp, and `--json` stays byte-identical.
# No tmux window and no `claude` process is ever launched.
#
# config.json's half of the enabled/format resolution is read via jq ONCE, at
# lib.sh source time (like SESSION_NAME/ORCH_HASH), not on every say() call —
# a per-line jq fork would compound as adoption of say() grows. So set_cfg()
# below re-sources lib.sh after editing config.json, matching how a real
# process only ever sees the config it started with (nothing hot-reloads
# config.json mid-run). The env-var override half stays live on every call
# (a bare case statement, not a fork) — those tests don't need a re-source.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  unset ORCH_TIMESTAMPS ORCH_TIMESTAMP_FORMAT || true
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
}

set_cfg() { # <jq filter> — edits config.json then re-sources lib.sh so the
  # source-time-cached _ORCH_CFG_TIMESTAMPS_DEFAULT/_ORCH_CFG_TIMESTAMP_FORMAT_DEFAULT
  # pick up the new value (see the file header comment above).
  jq "$1" "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
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

@test "lib.sh sources cleanly under set -e when config.json does not exist yet at source time" {
  # Regression test: the source-time jq resolution (added to cache the
  # enabled-flag/format instead of re-reading config.json on every say()
  # call) used a bare `x="$(jq ...)"` assignment for the format default.
  # Under `set -e` (every real caller sources lib.sh with it on), a plain
  # assignment's command substitution failing — e.g. jq erroring because
  # CONFIG doesn't exist, a fresh install or partial test scaffold — aborts
  # the ENTIRE sourcing script, not just the sole default lookup. This must
  # never happen: config.json missing is a legitimate, common state (nothing
  # in the toolkit requires it to exist up front).
  local root="$BATS_TEST_TMPDIR/no_config_root"
  mkdir -p "$root/_orch"
  rm -f "$root/_orch/config.json"
  run bash -c '
    set -euo pipefail
    export ORCH_ROOT="'"$root"'"
    unset ORCH_TIMESTAMPS ORCH_TIMESTAMP_FORMAT || true
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    say "still alive"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"still alive"* ]]
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

# --- config resolved once at source time, not per say() call -----------------------
# (review finding on PR #90: say() must not shell out to jq on every printed
# line — see the header comment above for the caching design.)

@test "say() forks jq zero times per call (only at lib.sh source time)" {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  COUNTER="$BATS_TEST_TMPDIR/jq-calls"
  : > "$COUNTER"
  real_jq="$(command -v jq)"
  cat > "$STUBBIN/jq" <<EOF
#!/usr/bin/env bash
printf 'x\n' >> "$COUNTER"
exec "$real_jq" "\$@"
EOF
  chmod +x "$STUBBIN/jq"
  PATH="$STUBBIN:$PATH"

  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
  after_source="$(wc -l < "$COUNTER")"
  [ "$after_source" -gt 0 ]  # lib.sh's own sourcing legitimately calls jq (config resolution here + elsewhere)

  say "one" >/dev/null
  say "two" >/dev/null
  say "three" >/dev/null
  after_calls="$(wc -l < "$COUNTER")"
  [ "$after_calls" -eq "$after_source" ]  # zero additional jq forks across 3 say() calls
}

# --- standalone-copy-of-orch fallback (review finding: confirm reachable, not dead) -

@test "orch: say() fallback works when _orch/lib.sh is not present (standalone copy)" {
  WORK="$BATS_TEST_TMPDIR/standalone"
  mkdir -p "$WORK/_orch/state"
  cp "$BATS_TEST_DIRNAME/../orch" "$WORK/orch"
  chmod +x "$WORK/orch"
  # No _orch/lib.sh copied — this is the exact shape tests/orchlogs_cli.bats
  # already relies on. Hit a say() call site (the "no <name> log yet" message)
  # with no lib.sh sourced, to prove the fallback at orch:28 is load-bearing.
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ROOT="$WORK" "$WORK/orch" --repo "$WORK" logs heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"no heartbeat log yet"* ]]
  # No timestamp: without lib.sh there is no config/env resolution at all,
  # only the bare-echo fallback.
  [[ "$output" != [0-9][0-9][0-9][0-9]-* ]]
}

@test "orch: the declare -F guard never shadows lib.sh's real say() when lib.sh IS present" {
  # Review finding: 'command -v say' can misreport a shell FUNCTION named say
  # on macOS bash 3.2, which would silently replace the real, config/env-aware
  # say() with the bare fallback even though lib.sh is loaded. Assert the
  # guard's condition directly: once lib.sh defines say as a function,
  # `declare -F say` must report it defined (guard does not re-fire), so a
  # normal (lib.sh-present) run keeps getting timestamped output.
  orch_e2e_setup
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
  grep -q '^declare -F say >/dev/null 2>&1 || say()' "$ORCH"
}
