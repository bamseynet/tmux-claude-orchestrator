# bats >=1.5 suite-wide setup (#191). Runs once per `bats` invocation, covers
# every file in this directory, and the exported env reaches `run bash -c`
# children.
#
# Dozens of test files write an inline `$STUBBIN/tmux` that `exit 0`s on subcommands
# it does not know, so `tmux show-buffer` always "succeeds" and send_prompt's
# paste-buffer poll (_orch/lib.sh) runs to its 50 x 0.1s cap on every stubbed
# spawn (~5.5s each). One poll is enough for a stub: the real-tmux semantics
# are exercised by tests/core_send_prompt.bats, which pins the 50 default by
# unsetting the knob itself. `:-` keeps a caller-exported value.
setup_suite() {
  export ORCH_SEND_POLL_TRIES="${ORCH_SEND_POLL_TRIES:-1}"
  # #204: spawn.sh's trust preflight reads Claude Code's config (~/.claude.json
  # by default). Suite tests spawn into throwaway repos that no real config
  # lists, so bypass it suite-wide; issue204_trust.bats unsets this and points
  # CLAUDE_CONFIG_DIR at a scratch dir.
  export ORCH_SKIP_TRUST_CHECK="${ORCH_SKIP_TRUST_CHECK:-1}"
  # Lets issue191_suite_poll_knob.bats prove this hook ran at all.
  export _ORCH_TEST_SETUP_SUITE_RAN=1
}
