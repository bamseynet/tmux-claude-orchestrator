#!/usr/bin/env bash
# _orch/watchdog.sh — per-window sweep with two responsibilities:
#   (1) Rate-limit recovery: when a pane shows a rate-limit error, wait out the
#       cooldown then tell that session to re-run the EXACT command (not a
#       workaround). A plain "continue" makes Claude skip the failed step.
#   (2) Liveness sweep: detect stalled or never-started workers. The master only
#       reacts to inbox events, so a worker whose pane has not changed for a while
#       (idle at an empty prompt / stuck on the startup banner) would otherwise go
#       unnoticed. When one is found, append a single "stalled" event to the inbox.
#   (3) Dead-worker reconciliation: if a worker window is killed or its claude
#       session dies, no Stop hook fires and workers/<id>.json stays "working"
#       forever, so the task is silently lost. Detect a status file that still says
#       "spawning"/"working" but has NO live tmux window, mark it "dead", notify
#       the master once, and prune its ../wt/<id> worktree + orch/<id> branch (issue
#       #37) so the path frees up for a respawn without waiting on `orch clean`.
#       Unlike (1)/(2) this iterates STATUS FILES (the window is gone, so a window
#       sweep would never see it).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

S="$SESSION_NAME"
cfg="$here/config.json"
interval="$(jq -r '.watchdog.check_interval // 15' "$cfg")"
cooldown="$(jq -r '.watchdog.cooldown_seconds // 65' "$cfg")"
stall="$(jq -r '.watchdog.stall_seconds // 90' "$cfg")"
rl_regex="$(jq -r '.watchdog.rate_limit_regex // "rate limit|429|overloaded|too many requests|usage limit"' "$cfg")"

# Consecutive ticks a worker must show "active status but no window" before we
# declare it dead. Debounces the sub-second gap in spawn.sh between writing the
# "spawning" status file and creating the tmux window, so a just-spawned worker is
# never mis-flagged. Overridable via env for tests.
DEAD_CONFIRM_TICKS="${DEAD_CONFIRM_TICKS:-2}"

# Pure predicate (no tmux, no fs): is a worker an orphan? True only when its status
# is still active (spawning/working) AND its id is not among the live window names.
# <live_windows> is a newline-separated list of tmux window names.
worker_is_orphaned() { # <live_windows> <status> <id>  -> 0 if orphaned
  case "$2" in working | spawning) ;; *) return 1 ;; esac
  printf '%s\n' "$1" | grep -Fxq "$3" && return 1
  return 0
}

# Pure predicate (no tmux, no fs): does this pane text show a rate-limit error?
# Broadened beyond "rate limit"/429/overloaded to also catch phrasing like
# "usage limit reached" that providers use instead of a literal "rate limit".
rate_limited() { # <pane_text>  -> 0 if it looks rate-limited
  printf '%s\n' "$1" | grep -qiE "$rl_regex"
}

# (1) Non-blocking rate-limit cooldown. Per-worker cooldown-until timestamp lives in
# $STATE_DIR/.rl-<window> instead of an inline `sleep`, so a rate-limited worker is
# skipped on subsequent ticks WITHOUT blocking the sweep of every other window.
# Once the cooldown elapses we verify the limit actually cleared before nudging the
# worker to retry: if it is still rate-limited we simply extend the cooldown rather
# than nudging into a wall.
#
# Prints exactly one of:
#   detected  - just started a new cooldown
#   skip      - still inside an existing cooldown window
#   extended  - cooldown elapsed but the pane is still rate-limited; cooldown reset
#   nudge     - cooldown elapsed and the limit cleared; caller should send the retry
#   (empty)   - not rate-limited and no cooldown in progress (exit status 1)
rl_action() { # <window> <pane_text> <now> <cooldown_seconds>
  local w="$1" pane="$2" now="$3" cd="$4"
  local f="$STATE_DIR/.rl-$w" until
  if [ -f "$f" ]; then
    until="$(cat "$f" 2>/dev/null || echo 0)"
    if [ "$now" -lt "$until" ]; then
      echo "skip"
      return 0
    fi
    if rate_limited "$pane"; then
      echo $((now + cd)) > "$f"
      echo "extended"
      return 0
    fi
    rm -f "$f"
    echo "nudge"
    return 0
  fi
  if rate_limited "$pane"; then
    echo $((now + cd)) > "$f"
    echo "detected"
    return 0
  fi
  return 1
}

# (3) Dead-worker reconciliation sweep. Given the live window-name list, scan every
# worker status file; a worker that is "active" but has no window is confirmed over
# DEAD_CONFIRM_TICKS ticks (via a per-worker debounce marker), then marked "dead"
# with a single inbox event. Reuses report.sh, whose contract is exactly
# {"id","event":"dead","ts"} + status=dead — so the master is notified once and the
# now-"dead" status keeps later ticks from re-emitting.
dead_sweep() { # <live_windows>
  local windows="$1" f id status dm misses
  for f in "$WORKERS_DIR"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json)"
    status="$(jq -r '.status // ""' "$f" 2>/dev/null || echo "")"
    dm="$STATE_DIR/.dead-$id"
    if worker_is_orphaned "$windows" "$status" "$id"; then
      misses="$(cat "$dm" 2>/dev/null || echo 0)"
      misses=$((misses + 1))
      if [ "$misses" -ge "$DEAD_CONFIRM_TICKS" ]; then
        "$here/report.sh" "$id" dead >/dev/null 2>&1 || true
        rm -f "$dm"
        prune_dead_worktree "${PROJECT_ROOT:-$(pwd)}" "$id"
        log "watchdog: worker '$id' dead (no live window, was $status); notified master"
      else
        printf '%s\n' "$misses" > "$dm"
      fi
    else
      # Window present, or a terminal status -> clear any pending debounce.
      rm -f "$dm"
    fi
  done
}

# Only run the long-lived loop when executed as a script; when sourced (e.g. by the
# hermetic bats tests) the helpers above are exposed without starting the loop.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
log "watchdog start (interval=${interval}s cooldown=${cooldown}s stall=${stall}s)"

while [ ! -f "$STATE_DIR/.stop" ]; do
  # Capture the live window names once per tick; reused by both sweeps below.
  windows="$(tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null)"
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    # Capture the pane once per window per tick and reuse it (keeps the sweep cheap).
    pane="$(pane_tail "$S:$w" 25)"

    # (1) non-blocking rate-limit cooldown + retry nudge (per-worker, never sleeps
    # the sweep — see rl_action() above).
    now="$(date +%s)"
    rl_result="$(rl_action "$w" "$pane" "$now" "$cooldown")" && rl_hit=1 || rl_hit=0
    if [ "$rl_hit" = "1" ]; then
      case "$rl_result" in
        detected)
          log "rate limit detected on '$w'; cooling ${cooldown}s (non-blocking)"
          ;;
        skip)
          : # still cooling; nothing to do this tick
          ;;
        extended)
          log "rate limit still active on '$w' after cooldown; extending ${cooldown}s"
          ;;
        nudge)
          wait_ready "$S:$w" 10 || true
          send_prompt "$S:$w" "That was a TEMPORARY rate limit, not a bug. Re-run the exact same command again — do NOT use a workaround."
          log "rate limit cleared on '$w'; sent retry nudge"
          ;;
      esac
      continue  # cooling, extending, or pane just changed -> skip the stall check
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
  done < <(printf '%s\n' "$windows")

  # (3) reconcile killed/dead workers against the same live window list.
  dead_sweep "$windows"

  sleep "$interval"
done
log "watchdog stop"
fi
