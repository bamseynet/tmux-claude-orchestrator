#!/usr/bin/env bash
# _orch/channel/launch.sh -- master-launch helpers for the opt-in channel delivery
# path (issue #212). Sourced by bootstrap.sh (after lib.sh); never run directly.

# Prepare the channel server and print the extra `claude` flags, or print nothing
# and return 1 (fail open: the master launches exactly as today, tmux injection).
# Registration goes through a generated --mcp-config file under $STATE_DIR, so the
# target repo's own .mcp.json is never touched.
channel_launch_flags() { # <orch dir> -> prints " --mcp-config <f> --dangerously-load-development-channels server:orch"
  local dir="$1/channel" cfg="$STATE_DIR/channel-mcp.json"
  local node_bin="${ORCH_NODE_BIN:-node}"
  if ! command -v "$node_bin" >/dev/null 2>&1; then
    log "delivery.channel on but node is missing; falling back to tmux injection"; return 1
  fi
  # Re-run npm ci when the lockfile changed since the last install (an `orch
  # update` swaps in a new package-lock.json but leaves node_modules alone, so a
  # bare "sdk dir exists" check would keep running the old pinned version).
  local stamp="$dir/node_modules/.orch-lock-stamp" want=""
  [ -f "$dir/package-lock.json" ] && want="$(cksum < "$dir/package-lock.json" 2>/dev/null)"
  if [ ! -d "$dir/node_modules/@modelcontextprotocol/sdk" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
    if command -v npm >/dev/null 2>&1 && [ -n "$want" ]; then
      npm ci --prefix "$dir" --silent >>"$LOG" 2>&1 && printf '%s\n' "$want" > "$stamp" || true
    fi
    if [ ! -d "$dir/node_modules/@modelcontextprotocol/sdk" ]; then
      log "delivery.channel on but channel deps are not installed (npm ci --prefix $dir); falling back to tmux injection"
      return 1
    fi
  fi
  mkdir -p "$STATE_DIR"
  jq -n --arg srv "$dir/server.mjs" --arg st "$STATE_DIR" --arg node "$node_bin" \
    '{mcpServers:{orch:{command:$node,args:[$srv],env:{ORCH_STATE_DIR:$st}}}}' \
    > "$cfg.tmp.$$" && mv -f "$cfg.tmp.$$" "$cfg" || { rm -f "$cfg.tmp.$$"; return 1; }
  printf ' --mcp-config %q --dangerously-load-development-channels server:orch' "$cfg"
}

# Answer the master's startup dialogs for the channel launch. Polls the pane:
#   "New MCP server found"        -> Up Up Enter  (the cursor starts on "Continue
#                                    without", so a bare Enter would REFUSE the
#                                    server and the channel would silently never load)
#   "Loading development channels" -> Enter        (cursor starts on "I am using this")
# Each dialog is checked on its own (not if/elif on the raw text): an answered
# dialog's text can linger in the 40-row tail and must not shadow the next one.
# Returns 0 once the prompt is ready with no dialog showing, 1 on timeout, 2 on
# timeout with a channel dialog on screen at the end -- neither is in pane_has_dialog,
# and its "❯ 1." row matches TUI_READY_REGEX, so the caller must NOT treat the
# pane as ready (a pasted role prompt would land in the dialog). On 1 the caller
# carries on and the heartbeat falls back to tmux injection because no loaded
# liveness file ever appears.
channel_answer_startup_dialogs() { # <target> [timeout_s]
  local t="${2:-30}" i=0 tail_ mcp_done=0 dev_done=0 mcp_up dev_up
  case "$t" in ''|*[!0-9]*) t=30 ;; esac
  while [ "$i" -lt "$t" ]; do
    tail_="$(pane_tail "$1" 40)"
    mcp_up=0; dev_up=0
    printf '%s\n' "$tail_" | grep -q 'New MCP server found' && mcp_up=1
    printf '%s\n' "$tail_" | grep -q 'Loading development channels' && dev_up=1
    if [ "$mcp_up" -eq 1 ] && [ "$mcp_done" -eq 0 ]; then
      tmux send-keys -t "$1" Up Up Enter; mcp_done=1
      log "channel launch: answered 'New MCP server found' (Up Up Enter -> Use this MCP server)"
    elif [ "$dev_up" -eq 1 ] && [ "$dev_done" -eq 0 ]; then
      tmux send-keys -t "$1" Enter; dev_done=1
      log "channel launch: accepted development-channels warning (Enter)"
    elif [ "$dev_done" -eq 1 ] && [ "$dev_up" -eq 0 ] && { [ "$mcp_up" -eq 0 ] || [ "$mcp_done" -eq 1 ]; } && is_ready "$1"; then
      # Only with no LIVE channel dialog in view: its "❯ 1." row satisfies is_ready.
      # MCP-dialog text after both were answered is stale scrollback (the dev
      # warning only renders once the MCP dialog is gone), so it must not block.
      return 0
    fi
    sleep 1; i=$((i + 1))
  done
  log "channel launch: startup dialogs not resolved within ${t}s; heartbeat will use tmux injection"
  # Re-look once: a dialog that rendered late, or one whose keypress did not take.
  tail_="$(pane_tail "$1" 40)"
  printf '%s\n' "$tail_" | grep -q 'Loading development channels' && return 2
  # MCP text only counts while the dev warning was never reached (answered = stale).
  [ "$dev_done" -eq 0 ] && printf '%s\n' "$tail_" | grep -q 'New MCP server found' && return 2
  return 1
}
