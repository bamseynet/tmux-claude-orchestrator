#!/usr/bin/env bash
# _orch/watchdog.sh — scans every window for rate-limit output. When found, waits out
# the cooldown then tells that session to re-run the EXACT command (not a workaround).
# A plain "continue" makes Claude skip the failed step; the explicit message is the fix.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

S="$SESSION_NAME"
cfg="$here/config.json"
interval="$(jq -r '.watchdog.check_interval // 15' "$cfg")"
cooldown="$(jq -r '.watchdog.cooldown_seconds // 65' "$cfg")"

log "watchdog start (interval=${interval}s cooldown=${cooldown}s)"

while [ ! -f "$STATE_DIR/.stop" ]; do
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    if pane_tail "$S:$w" 20 | grep -qiE 'rate limit|429|overloaded|too many requests'; then
      log "rate limit detected on '$w'; cooling ${cooldown}s"
      sleep "$cooldown"
      wait_ready "$S:$w" 10 || true
      send_prompt "$S:$w" "That was a TEMPORARY rate limit, not a bug. Re-run the exact same command again — do NOT use a workaround."
      log "sent retry nudge to '$w'"
    fi
  done < <(tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null)
  sleep "$interval"
done
log "watchdog stop"
