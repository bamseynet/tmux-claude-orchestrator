#!/usr/bin/env bats
# Hermetic test for issue #38: heartbeat must requeue (never inject over) an
# unsent operator draft sitting in the master pane's input line. tmux is stubbed
# so no real tmux window is ever touched; the "master pane" content is driven by
# $PANE_TEXT_FILE, read by the tmux stub's capture-pane.

# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  printf '❯ some unsent draft text' > "$PANE_TEXT_FILE"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  capture-pane) cat "$PANE_TEXT_FILE" ;;
  load-buffer)  cat > /dev/null ;;
  show-buffer)  exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export SESSION_NAME="orch"
  export ORCH_WINDOW="orchestrator"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
}

@test "heartbeat requeues events instead of injecting when the master pane holds a draft" {
  printf '%s\n' '{"id":"w1","event":"turn-end"}' >> "$INBOX"

  events="$(drain_inbox)"
  [ -n "$events" ]

  if ! wait_ready "$SESSION_NAME:$ORCH_WINDOW" 1; then
    printf '%s\n' "$events" >> "$INBOX"
  elif pane_has_draft "$SESSION_NAME:$ORCH_WINDOW"; then
    printf '%s\n' "$events" >> "$INBOX"
  else
    send_prompt "$SESSION_NAME:$ORCH_WINDOW" "[orchestrator heartbeat] $events"
  fi

  # The event must survive in the inbox, unconsumed.
  [ -s "$INBOX" ]
  grep -q '"id":"w1"' "$INBOX"

  # send_prompt must never have been invoked: no paste-buffer call went out.
  ! grep -q 'paste-buffer' "$CALLS"
}

@test "heartbeat injects normally once the draft is gone (regression guard)" {
  printf '❯ ' > "$PANE_TEXT_FILE"
  printf '%s\n' '{"id":"w1","event":"turn-end"}' >> "$INBOX"

  events="$(drain_inbox)"
  if ! wait_ready "$SESSION_NAME:$ORCH_WINDOW" 1; then
    printf '%s\n' "$events" >> "$INBOX"
  elif pane_has_draft "$SESSION_NAME:$ORCH_WINDOW"; then
    printf '%s\n' "$events" >> "$INBOX"
  else
    send_prompt "$SESSION_NAME:$ORCH_WINDOW" "[orchestrator heartbeat] $events"
  fi

  refute_grep '"id":"w1"' "$INBOX"
  grep -q 'paste-buffer' "$CALLS"
}
