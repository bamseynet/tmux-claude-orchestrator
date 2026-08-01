#!/usr/bin/env bash
# _orch/watchdog.sh — per-window sweep with two responsibilities:
#   (1) Rate-limit recovery: when a pane shows a rate-limit error, wait out the
#       cooldown then tell that session to re-run the EXACT command (not a
#       workaround). A plain "continue" makes Claude skip the failed step.
#   (2) Liveness sweep: detect stalled or never-started workers. The master only
#       reacts to inbox events, so a worker whose pane has not changed for a while
#       (idle at an empty prompt / stuck on the startup banner) would otherwise go
#       unnoticed. When one is found, append a single "stalled" event to the inbox.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

S="$SESSION_NAME"
cfg="$here/config.json"
interval="$(jq -r '.watchdog.check_interval // 15' "$cfg")"
cooldown="$(jq -r '.watchdog.cooldown_seconds // 65' "$cfg")"
stall="$(jq -r '.watchdog.stall_seconds // 90' "$cfg")"

log "watchdog start (interval=${interval}s cooldown=${cooldown}s stall=${stall}s)"

while [ ! -f "$STATE_DIR/.stop" ]; do
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    # Capture the pane once per window per tick and reuse it (keeps the sweep cheap).
    pane="$(pane_tail "$S:$w" 25)"

    # (1) rate-limit cooldown + retry nudge
    if printf '%s\n' "$pane" | grep -qiE 'rate limit|429|overloaded|too many requests'; then
      log "rate limit detected on '$w'; cooling ${cooldown}s"
      sleep "$cooldown"
      wait_ready "$S:$w" 10 || true
      send_prompt "$S:$w" "That was a TEMPORARY rate limit, not a bug. Re-run the exact same command again — do NOT use a workaround."
      log "sent retry nudge to '$w'"
      continue  # pane just changed; skip the stall check for this tick
    fi

    # (2) liveness sweep: flag a stalled/never-started worker once per stall episode.
    sig="$(printf '%s' "$pane" | cksum | cut -d' ' -f1)"
    wf="$STATE_DIR/.wd-$w"
    now="$(date +%s)"
    prev_sig=""; first="$now"; alerted=0
    if [ -f "$wf" ]; then
      { IFS= read -r prev_sig; IFS= read -r first; IFS= read -r alerted; } < "$wf" || true
      : "${first:=$now}"; : "${alerted:=0}"
    fi

    if [ "$sig" != "$prev_sig" ]; then
      # Pane changed -> reset the stall episode (first-seen now, not yet alerted).
      printf '%s\n%s\n%s\n' "$sig" "$now" "0" > "$wf"
    else
      age=$(( now - first ))
      status="$(jq -r '.status // ""' "$WORKERS_DIR/$w.json" 2>/dev/null || echo "")"
      # Idle if no spinner, or still parked on the startup Welcome banner.
      if [ "$age" -ge "$stall" ] && [ "$alerted" != "1" ] \
         && { [ "$status" = "spawning" ] || [ "$status" = "working" ]; } \
         && { ! printf '%s\n' "$pane" | grep -qiE 'esc to interrupt|Running…|Compacting' \
              || printf '%s\n' "$pane" | grep -qi 'Welcome'; }; then
        printf '{"id":"%s","event":"stalled","ts":"%s"}\n' "$w" "$(date -u +%FT%TZ)" >> "$INBOX"
        log "watchdog: worker '$w' stalled (${age}s no change, status=$status); notified master"
        alerted=1
      fi
      printf '%s\n%s\n%s\n' "$sig" "$first" "$alerted" > "$wf"
    fi
  done < <(tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null)
  sleep "$interval"
done
log "watchdog stop"
