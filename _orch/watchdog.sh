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
#       the master once, and prune its ../wt/<hash>/<id> worktree + orch/<hash>/<id>
#       branch (issue #37; namespaced per-install since #86) so the path frees up
#       for a respawn without waiting on `orch clean`.
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
# needs_input_realert: how long a worker may sit in "needs-input" with an
# unchanged pane before the sweep treats it as un-serviced (issue #50 point 1/2).
needs_input_realert="$(jq -r '.watchdog.needs_input_realert_seconds // 600' "$cfg")"
# review_idle: how long ANY idle (pane-unchanged) worker must sit before its
# worktree is checked for unmerged commits (issue #50 point 3).
review_idle="$(jq -r '.watchdog.review_idle_seconds // 300' "$cfg")"
# realert base/cap: bounded exponential backoff shared by every re-alerting signal
# below (issue #50 point 4) — replaces the old fire-once "alerted" flag.
realert_base="$(jq -r '.watchdog.realert_seconds // 90' "$cfg")"
realert_max="$(jq -r '.watchdog.realert_max_seconds // 1800' "$cfg")"
rl_regex="$(jq -r '.watchdog.rate_limit_regex // "rate limit|429|overloaded|too many requests|usage limit"' "$cfg")"
# reap_after: how long a terminal (done/spawn-failed) worker's state file survives
# before the sweep reaps it (issue #46). Retention, not instant delete, so
# `orch status` still shows recent history instead of vanishing the moment a
# worker finishes.
reap_after="$(jq -r '.watchdog.reap_terminal_after_seconds // 1800' "$cfg")"

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

# Prints the live window list for session $S, or FAILS (returns 1, prints
# nothing) if the session itself does not exist (issue #114). A plain
# `tmux list-windows -t "$S" 2>/dev/null` cannot be trusted for this: on a gone
# session/server it fails, but that failure was previously swallowed into an
# empty string -- indistinguishable from "the session is up but happens to
# have zero windows" -- which is exactly the case that made dead_sweep treat
# every active worker as simultaneously dead when the operator killed/exited
# the whole tmux session (the loops keep running, reparented, per #114).
# Checking session_exists() first (exact-match, not tmux's ambiguous-prefix
# has-session) lets a caller skip the sweep entirely for the tick instead of
# handing dead_sweep a windows list it cannot trust.
live_windows() { # -> prints newline-separated window names; returns 1 if $S is gone
  session_exists "$S" || return 1
  tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null
}

# Pure predicate (no tmux, no fs): does this pane text show a rate-limit error?
# Broadened beyond "rate limit"/429/overloaded to also catch phrasing like
# "usage limit reached" that providers use instead of a literal "rate limit".
rate_limited() { # <pane_text>  -> 0 if it looks rate-limited
  printf '%s\n' "$1" | grep -qiE "$rl_regex"
}

# Pure predicate (no tmux, no fs): is a re-alert due now, given bounded exponential
# backoff? <count>=0 means "never yet alerted" -> always due (the caller gates the
# very first alert on its own age>=threshold check). Each subsequent alert waits
# base*2^(count-1), capped at <max>, since the last alert. Replaces the old
# fire-once "alerted" flag (issue #50 point 4) so a single lost signal can't strand
# a worker — the sweep just keeps re-emitting, slower each time, until acknowledged.
realert_due() { # <last_alert_ts> <count> <base_seconds> <max_seconds> <now>  -> 0 if due
  local last="$1" count="$2" base="$3" max="$4" now="$5"
  [ "$count" -le 0 ] && return 0
  local mult=$((1 << (count - 1)))
  local wait=$((base * mult))
  [ "$wait" -gt "$max" ] && wait="$max"
  [ "$now" -ge $((last + wait)) ]
}

# Pure-ish predicate (git only, no tmux): how many commits is <id>'s worktree
# branch ahead of the upstream default branch? Prints 0 (and fails) when the
# worktree does not exist, so callers can treat "no worktree" as "nothing to
# review" without a separate existence check. Prefers origin/main, falling back to
# origin/HEAD then a local `main` for repos without that exact remote branch
# (e.g. hermetic test repos with no remote at all).
worker_branch_ahead() { # <project_root> <id>  -> prints ahead-count
  local proj="$1" id="$2" wdir base
  wdir="$(worker_wdir "$proj" "$id")"
  # Back-compat (issue #86): a worker spawned before this install upgraded to
  # the namespaced layout still lives at the pre-#86 ../wt/<id> worktree.
  [ -d "$wdir" ] || wdir="$(legacy_worker_wdir "$proj" "$id")"
  [ -d "$wdir" ] || { echo 0; return 1; }
  if git -C "$wdir" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base="origin/main"
  elif git -C "$wdir" rev-parse --verify -q origin/HEAD >/dev/null 2>&1; then
    base="origin/HEAD"
  elif git -C "$wdir" rev-parse --verify -q main >/dev/null 2>&1; then
    base="main"
  else
    echo 0
    return 1
  fi
  git -C "$wdir" rev-list --count "$base..HEAD" 2>/dev/null || echo 0
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

# (2) Liveness + review sweep for one window/worker per tick. Flags a stalled
# worker, a worker abandoned in needs-input, and/or an idle worker sitting on
# unmerged commits — each with bounded/backoff re-alerting instead of firing once
# (issue #50). State lives in two per-worker files:
#   $STATE_DIR/.wd-<w>      sig / first-seen / last-alert-ts / alert-count
#   $STATE_DIR/.review-<w>  last-alert-ts / alert-count (ready-for-review only)
liveness_check() { # <w> <pane_text> <now>
  local w="$1" pane="$2" now="$3"
  local sig wf prev_sig first last_alert alert_count
  sig="$(printf '%s' "$pane" | cksum | cut -d' ' -f1)"
  wf="$STATE_DIR/.wd-$w"
  prev_sig=""; first="$now"; last_alert=0; alert_count=0
  if [ -f "$wf" ]; then
    { IFS= read -r prev_sig; IFS= read -r first; IFS= read -r last_alert; IFS= read -r alert_count; } < "$wf" || true
    : "${first:=$now}"; : "${last_alert:=0}"; : "${alert_count:=0}"
  fi

  if [ "$sig" != "$prev_sig" ]; then
    # Pane changed -> reset the stall episode (first-seen now, not yet alerted).
    printf '%s\n%s\n%s\n%s\n' "$sig" "$now" "0" "0" > "$wf"
    return 0
  fi

  local age status thr="" ev=""
  age=$(( now - first ))
  status="$(jq -r '.status // ""' "$WORKERS_DIR/$w.json" 2>/dev/null || echo "")"
  case "$status" in
    spawning | working)
      # Idle if no spinner, or still parked on the startup Welcome banner.
      if ! printf '%s\n' "$pane" | grep -qiE 'esc to interrupt|Running…|Compacting' \
         || printf '%s\n' "$pane" | grep -qi 'Welcome'; then
        thr="$stall"; ev="stalled"
      fi
      ;;
    needs-input)
      # Abandoned wait, not a fresh input request -> a distinct event name so the
      # master can tell "worker is asking something new" apart from "this ask has
      # been sitting unserviced" (issue #50 point 2).
      thr="$needs_input_realert"; ev="needs-input-stalled"
      ;;
  esac

  if [ -n "$thr" ] && [ "$age" -ge "$thr" ] \
     && { [ "$alert_count" -eq 0 ] || realert_due "$last_alert" "$alert_count" "$realert_base" "$realert_max" "$now"; }; then
    ev_line="$(printf '{"id":"%s","event":"%s","ts":"%s"}' "$w" "$ev" "$(date -u +%FT%TZ)")"
    printf '%s\n' "$ev_line" >> "$INBOX"
    printf '%s\n' "$ev_line" >> "$STATE_DIR/events.jsonl"
    log "watchdog: worker '$w' $ev (${age}s no change, status=$status, alert #$((alert_count + 1))); notified master"
    last_alert="$now"
    alert_count=$((alert_count + 1))
  fi
  printf '%s\n%s\n%s\n%s\n' "$sig" "$first" "$last_alert" "$alert_count" > "$wf"

  # (4) committed-work-idle detector: an idle worker (pane unchanged for
  # review_idle_seconds) whose branch has commits ahead of the upstream default
  # branch gets a "ready-for-review" event even if it never sent a clean "done"
  # (issue #50 point 3, the highest-value check here).
  [ "$age" -ge "$review_idle" ] || return 0
  local ahead rf r_last r_count
  ahead="$(worker_branch_ahead "${PROJECT_ROOT:-$(pwd)}" "$w")" || true
  rf="$STATE_DIR/.review-$w"
  r_last=0; r_count=0
  [ -f "$rf" ] && { IFS= read -r r_last; IFS= read -r r_count; } < "$rf" || true
  : "${r_last:=0}"; : "${r_count:=0}"
  if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$r_count" -eq 0 ] || realert_due "$r_last" "$r_count" "$realert_base" "$realert_max" "$now"; then
      rfr_line="$(printf '{"id":"%s","event":"ready-for-review","ts":"%s"}' "$w" "$(date -u +%FT%TZ)")"
      printf '%s\n' "$rfr_line" >> "$INBOX"
      printf '%s\n' "$rfr_line" >> "$STATE_DIR/events.jsonl"
      log "watchdog: worker '$w' ready-for-review (${ahead} commit(s) ahead, idle ${age}s, alert #$((r_count + 1))); notified master"
      r_last="$now"; r_count=$((r_count + 1))
    fi
    printf '%s\n%s\n' "$r_last" "$r_count" > "$rf"
  else
    # Nothing ahead (merged, or no worktree) -> clear so a future commit starts a
    # fresh alert episode instead of inheriting old backoff state.
    rm -f "$rf"
  fi
}

# Runs the rate-limit + liveness sweep for exactly one window/worker per tick.
# Skips the master/orchestrator window entirely: it is a heavy Claude session
# that can trip the same rate-limit/liveness regexes as a worker, and
# send_prompt-ing a retry nudge into the operator's own pane is both a bug and
# a prompt-injection vector (issue #55).
sweep_window() { # <window> <cooldown_seconds>
  local w="$1" cd="$2"
  [ "$w" = "$ORCH_WINDOW" ] && return 0
  local pane now rl_result rl_hit
  pane="$(pane_tail "$S:$w" 25)"

  now="$(date +%s)"
  rl_result="$(rl_action "$w" "$pane" "$now" "$cd")" && rl_hit=1 || rl_hit=0
  if [ "$rl_hit" = "1" ]; then
    case "$rl_result" in
      detected)
        log "rate limit detected on '$w'; cooling ${cd}s (non-blocking)"
        ;;
      skip)
        : # still cooling; nothing to do this tick
        ;;
      extended)
        log "rate limit still active on '$w' after cooldown; extending ${cd}s"
        ;;
      nudge)
        # issue #70: a human-managed worker is being hand-driven — sending an
        # automated retry into its pane would race/interleave with human
        # keystrokes exactly like the collisions this flag exists to prevent.
        # Still log (history/reporting unaffected), just don't inject.
        if is_human_managed "$w"; then
          log "rate limit cleared on '$w'; skipping retry nudge (human-managed)"
        else
          wait_ready "$S:$w" 10 || true
          send_prompt "$S:$w" "That was a TEMPORARY rate limit, not a bug. Re-run the exact same command again — do NOT use a workaround."
          log "rate limit cleared on '$w'; sent retry nudge"
        fi
        ;;
    esac
    return 0  # cooling, extending, or pane just changed -> skip the stall check
  fi

  now="$(date +%s)"
  liveness_check "$w" "$pane" "$now"
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

# (4) Terminal-worker reaper (issue #46). Nothing ever deleted a done/spawn-failed
# worker's state file short of a manual `orch clean <id>`, so status.json steadily
# fills with finished workers. Retention-based rather than instant so `orch status`
# still shows recent history; `orch prune` (below) calls this with retention=0 to
# reap everything eligible right now.

# Pure predicate (no tmux, no fs): is a terminal worker's state file old enough to
# reap? Non-terminal statuses are NEVER reapable, regardless of age — this is the
# one invariant callers must never bypass.
worker_is_reapable() { # <status> <updated_epoch> <now> <retention_seconds> -> 0 if reapable
  local status="$1" updated="$2" now="$3" retention="$4"
  case "$status" in done | spawn-failed) ;; *) return 1 ;; esac
  [ "$now" -ge $((updated + retention)) ]
}

# Reap every terminal worker whose state file has aged past <retention_seconds>,
# reusing clean.sh's teardown (worktree/branch/status/scratch) for consistency with
# the manual `orch clean <id>` path. A worker that still holds a live tmux window
# is skipped even if its status is terminal — belt-and-braces alongside
# worker_is_reapable, since a window should never outlive a terminal status but a
# stale/racing status file is exactly the kind of thing this sweep must not trust
# blindly. <now> defaults to the real clock; tests pass it explicitly.
reap_terminal_workers() { # <retention_seconds> <live_windows> [now]
  local retention="$1" windows="$2" now="${3:-$(date -u +%s)}"
  local f id status ts epoch
  for f in "$WORKERS_DIR"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json)"
    status="$(jq -r '.status // ""' "$f" 2>/dev/null || echo "")"
    case "$status" in done | spawn-failed) ;; *) continue ;; esac
    printf '%s\n' "$windows" | grep -Fxq "$id" && continue
    ts="$(jq -r '.updated // .created // empty' "$f" 2>/dev/null)"
    epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || epoch=0
    worker_is_reapable "$status" "$epoch" "$now" "$retention" || continue
    "$here/clean.sh" "$id" >/dev/null 2>&1 || true
    log "watchdog: reaped terminal worker '$id' (status=$status, retention=${retention}s)"
    say "reaped $id"
  done
}

# Only run the long-lived loop when executed as a script; when sourced (e.g. by the
# hermetic bats tests) the helpers above are exposed without starting the loop.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_valid_session_name
  # One-shot `orch prune`: reap every terminal worker right now, ignoring
  # retention, then exit — no loop, no sleep.
  if [ "${1:-}" = "prune" ]; then
    windows="$(tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null)"
    reap_terminal_workers 0 "$windows"
    exit 0
  fi

log "watchdog start (interval=${interval}s cooldown=${cooldown}s stall=${stall}s)"

while [ ! -f "$STATE_DIR/.stop" ]; do
  # Capture the live window names once per tick; reused by both sweeps below.
  # If the session itself is gone (issue #114 -- e.g. this loop was orphaned
  # by a `tmux kill-session`/exit and reparented to systemd), skip the WHOLE
  # tick rather than sweeping against a windows list we can't trust: an empty
  # list here could mean "every window died" (real) or "the session is gone"
  # (not a worker failure at all -- would wrongly mark every active worker
  # dead and prune every worktree/branch in one debounce window).
  if ! windows="$(live_windows)"; then
    log "watchdog: session '$S' not found this tick -- skipping sweep (orphaned loop or session not up yet)"
    sleep "$interval"
    continue
  fi
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    sweep_window "$w" "$cooldown"
  done < <(printf '%s\n' "$windows")

  # (3) reconcile killed/dead workers against the same live window list.
  dead_sweep "$windows"

  # (4) reap terminal workers older than retention.
  reap_terminal_workers "$reap_after" "$windows" >/dev/null

  sleep "$interval"
done
log "watchdog stop"
fi
