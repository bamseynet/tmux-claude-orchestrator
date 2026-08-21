#!/usr/bin/env bats
# Pins the shared fake-tmux fixture's own fidelity (issue #121 acceptance
# criteria): it must resolve `-t` by unambiguous PREFIX like real tmux (the
# #96 hijack case), and it must REJECT unknown flags rather than silently
# ignoring them (the #110 case). A fixture nobody tests is just a bigger
# version of the drift problem the issue describes.

setup() {
  export FAKE_TMUX_STATE="$BATS_TEST_TMPDIR/fake-tmux-state"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/helpers/fake-tmux.bash"
}

@test "fake-tmux: has-session resolves an unambiguous prefix (issue #96)" {
  fake_tmux_add_session "billing"
  run tmux has-session -t bill
  [ "$status" -eq 0 ]
}

@test "fake-tmux: has-session does NOT match a longer, differently-named session by accident" {
  fake_tmux_add_session "billing"
  # "bill" is a real prefix of "billing" above -- this proves the fixture
  # isn't doing an exact-only match that would make the previous test moot.
  run tmux has-session -t billin
  [ "$status" -eq 0 ]
  run tmux has-session -t billinx
  [ "$status" -ne 0 ]
}

@test "fake-tmux: has-session refuses an AMBIGUOUS prefix (two sessions share it)" {
  fake_tmux_add_session "billing"
  fake_tmux_add_session "bill-other"
  run tmux has-session -t bill
  [ "$status" -ne 0 ]
}

@test "fake-tmux: list-windows resolves the window part by unambiguous prefix too" {
  fake_tmux_add_session "test" "orchestrator"
  run tmux list-windows -t test -F '#{window_name}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"orchestrator"* ]]
}

@test "fake-tmux: unknown flags are REJECTED, not silently ignored (issue #110)" {
  fake_tmux_add_session "test"
  run tmux has-session -t test --bogus-flag
  [ "$status" -ne 0 ]
}

@test "fake-tmux: capture-pane -e can be made to simulate a tmux build that rejects -e" {
  fake_tmux_add_session "test" "orchestrator"
  fake_tmux_set_pane "test" "orchestrator" "hello"
  run tmux capture-pane -t test:orchestrator -p -e
  [ "$status" -eq 0 ]
  fake_tmux_reject_capture_e
  run tmux capture-pane -t test:orchestrator -p -e
  [ "$status" -ne 0 ]
}

@test "fake-tmux: capture-pane -e emits SGR escapes" {
  fake_tmux_add_session "test" "orchestrator"
  fake_tmux_set_pane "test" "orchestrator" "hello"
  run tmux capture-pane -t test:orchestrator -p -e
  [[ "$output" == *$'\033['* ]]
}

@test "fake-tmux: per-test override replaces exactly one subcommand" {
  fake_tmux_add_session "test"
  fake_tmux_override_send_keys() { echo "overridden: $*"; }
  run tmux send-keys -t test:orchestrator hi
  [ "$status" -eq 0 ]
  [[ "$output" == "overridden:"* ]]
  # has-session is untouched by the override -- still the real fixture behaviour.
  run tmux has-session -t nonexistent
  [ "$status" -ne 0 ]
}
