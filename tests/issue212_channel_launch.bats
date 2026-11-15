#!/usr/bin/env bats
# Issue #212: master launch helpers (_orch/channel/launch.sh) with a scripted tmux:
# capture-pane prints pane.<N> where N = number of send-keys calls so far.

setup() {
  unset SESSION_NAME
  STUBBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  PD="$BATS_TEST_TMPDIR/panes"; mkdir -p "$PD"
  KEYS="$BATS_TEST_TMPDIR/keys.log"; : > "$KEYS"; echo 0 > "$PD/n"
  cat > "$STUBBIN/tmux" <<EOS
#!/usr/bin/env bash
case "\${1:-}" in
  send-keys) shift; shift; shift; echo "\$*" >> "$KEYS"; echo \$(( \$(cat "$PD/n") + 1 )) > "$PD/n" ;;
  capture-pane) n=\$(cat "$PD/n"); f="$PD/pane.\$n"; [ -f "\$f" ] || f="\$(ls "$PD"/pane.* | sort -V | tail -1)"; cat "\$f" ;;
  list-sessions) echo orch ;;
esac
exit 0
EOS
  chmod +x "$STUBBIN/tmux"; PATH="$STUBBIN:$PATH"
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root" ORCH_WINDOW=orchestrator SESSION_NAME=orch
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/channel/launch.sh"
  mkdir -p "$STATE_DIR"
}

MCP_DLG='New MCP server found in this project: orch
  1. Use this MCP server
  2. Use this and all future MCP servers in this project
❯ 3. Continue without using this MCP server'
DEV_DLG='WARNING: Loading development channels
  Channels: server:orch
❯ 1. I am using this for local development
  2. Exit'

@test "dialogs: MCP-approval dialog gets Up Up Enter (never a bare Enter), then the dev warning gets Enter" {
  printf '%s\n' "$MCP_DLG" > "$PD/pane.0"
  printf '%s\n' "$DEV_DLG" > "$PD/pane.1"
  printf '%s\n' '❯ ' > "$PD/pane.2"
  run channel_answer_startup_dialogs orch:orchestrator 10
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$KEYS")" = "Up Up Enter" ]
  [ "$(sed -n 2p "$KEYS")" = "Enter" ]
  [ "$(wc -l < "$KEYS")" -eq 2 ]
}

@test "dialogs: only the dev warning (server already approved) -> a single Enter" {
  printf '%s\n' "$DEV_DLG" > "$PD/pane.0"
  printf '%s\n' '❯ ' > "$PD/pane.1"
  run channel_answer_startup_dialogs orch:orchestrator 10
  [ "$status" -eq 0 ]
  [ "$(cat "$KEYS")" = "Enter" ]
}

@test "dialogs: timeout with nothing recognisable sends no keys and returns 1 (fail open)" {
  printf '%s\n' 'loading...' > "$PD/pane.0"
  run channel_answer_startup_dialogs orch:orchestrator 2
  [ "$status" -eq 1 ]
  [ ! -s "$KEYS" ]
  grep -q 'tmux injection' "$LOG"
}

@test "dialogs: a lone MCP dialog never receives a bare Enter" {
  printf '%s\n' "$MCP_DLG" > "$PD/pane.0"
  run channel_answer_startup_dialogs orch:orchestrator 2
  ! grep -qx 'Enter' "$KEYS"
  [ "$(sed -n 1p "$KEYS")" = "Up Up Enter" ]
}

@test "flags: node missing -> no flags, returns 1 (launch unchanged)" {
  ORCH_NODE_BIN=definitely-not-node run channel_launch_flags "$ORCH_ROOT/_orch"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "flags: deps present -> --mcp-config + dev-channels flag, config registers server orch with ORCH_STATE_DIR" {
  command -v node >/dev/null || skip "node not installed"
  d="$ORCH_ROOT/_orch/channel"; mkdir -p "$d/node_modules/@modelcontextprotocol/sdk"
  run channel_launch_flags "$ORCH_ROOT/_orch"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dangerously-load-development-channels server:orch"* ]]
  [[ "$output" == *"--mcp-config "* ]]
  [ "$(jq -r '.mcpServers.orch.command' "$STATE_DIR/channel-mcp.json")" = "node" ]
  [ "$(jq -r '.mcpServers.orch.env.ORCH_STATE_DIR' "$STATE_DIR/channel-mcp.json")" = "$STATE_DIR" ]
}

@test "bootstrap: channel flags are computed only inside the delivery_channel_enabled gate, before the launch line" {
  b="$BATS_TEST_DIRNAME/../_orch/bootstrap.sh"
  init="$(grep -n '^  channel_flags=""' "$b" | head -1 | cut -d: -f1)"
  gate="$(grep -n 'if delivery_channel_enabled' "$b" | head -1 | cut -d: -f1)"
  call="$(grep -n 'channel_flags="\$(channel_launch_flags' "$b" | head -1 | cut -d: -f1)"
  launch="$(grep -n 'send-keys.*claude --dangerously-skip-permissions' "$b" | head -1 | cut -d: -f1)"
  [ -n "$init" ] && [ -n "$gate" ] && [ -n "$call" ] && [ -n "$launch" ]
  [ "$init" -lt "$gate" ] && [ "$gate" -lt "$call" ] && [ "$call" -lt "$launch" ]
  grep -q 'claude --dangerously-skip-permissions.*\${channel_flags}' "$b"
}
