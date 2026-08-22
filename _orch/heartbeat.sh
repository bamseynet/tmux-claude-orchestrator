#!/usr/bin/env bash
# _orch/heartbeat.sh — cheap external loop. Watches the inbox and wakes the master
# ONLY when there is a decision to make. The LLM never polls; bash does.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

# Atomically claim the current inbox by renaming it aside, then fold it into the
# pending-batch file. This closes the lost-events race (issue #10): the old
# `events="$(cat "$INBOX")"; : > "$INBOX"` read-then-truncate dropped any event a
# worker hook appended between the read and the truncate. Workers append with
# `>> "$INBOX"` (open-by-path), so once the inbox is renamed aside their appends
# open a brand-new inbox and can never fall into a truncation gap.
#
# Prints the pending-batch path on stdout when a batch is pending (either freshly
# claimed or left over from a crashed drain); returns non-zero and prints nothing
# when there is nothing to drain. `$INBOX` not existing yet is handled.
inbox_swap() { # -> echoes "$INBOX.processing" when a batch is pending
  local proc="$INBOX.processing" claim="$INBOX.claiming"
  if [ -e "$INBOX" ]; then
    # Atomic claim. After this rename, concurrent `>> "$INBOX"` appends open a
    # fresh inbox; nothing they write can land in the batch we just claimed.
    if mv "$INBOX" "$claim" 2>/dev/null; then
      # Fold the claimed batch into the pending file. Both are dead files no
      # worker ever opens, so this append is race-free. Appending (rather than
      # overwriting) preserves any batch orphaned by a crashed earlier drain.
      cat "$claim" >> "$proc" && rm -f "$claim"
    fi
  fi
  [ -s "$proc" ] || { rm -f "$proc" 2>/dev/null; return 1; }
  printf '%s\n' "$proc"
}

# Drain the inbox atomically. Prints all pending events on stdout and returns 0
# when there were events; returns non-zero and prints nothing when the inbox was
# empty or absent.
drain_inbox() {
  local proc
  proc="$(inbox_swap)" || return 1
  cat "$proc"
  rm -f "$proc"
}

# Status of worker <id>, or empty if its status file doesn't exist yet.
_worker_status() { # <id>
  local f="$WORKERS_DIR/$1.json"
  [ -f "$f" ] && jq -r '.status // empty' "$f" 2>/dev/null
}

# Task dependencies (issue #22): pop the first queue item whose `after` worker
# (if any) has reached "done", without disturbing the relative order of the
# items behind it. A dependency-less item is always eligible. Prints the item
# and rewrites the queue file minus that one line; returns 1 (no output, queue
# untouched) if the queue is empty or nothing in it is ready yet.
queue_pop_ready() {
  [ -s "$QUEUE" ] || return 1
  local line after found="" tmp="$QUEUE.tmp.$$"
  : > "$tmp"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "$found" ]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    after="$(jq -r '.after // empty' <<<"$line")"
    if [ -z "$after" ] || [ "$(_worker_status "$after")" = "done" ]; then
      found="$line"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$QUEUE"
  mv "$tmp" "$QUEUE"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Drain one pending spawn from the queue (issues #21/#31/#24, #22 task deps) if
# the unified resource gate now allows it AND at least one queued item's
# dependency (if any) is satisfied — e.g. a worker just freed a concurrency slot
# or a dependency worker just reported "done". Re-checks the gate itself, so
# it's safe to call every tick.
drain_queue_if_room() {
  [ -s "$QUEUE" ] || return 0
  if ! check_spawn_gate; then
    log "queue drain: still blocked ($GATE_REASON)"
    return 0
  fi
  local item id model task mode resume allow
  item="$(queue_pop_ready)" || return 0
  id="$(jq -r '.id' <<<"$item")"
  model="$(jq -r '.model' <<<"$item")"
  task="$(jq -r '.task' <<<"$item")"
  mode="$(jq -r '.mode' <<<"$item")"
  resume="$(jq -r '.resume' <<<"$item")"
  allow="$(jq -r '.allow_csv' <<<"$item")"

  local args=("$id" "$model" "$task")
  [ "$mode" = "--no-worktree" ] && args+=(--no-worktree)
  if [ -n "$resume" ]; then
    local rargs=(); read -ra rargs <<< "$resume"
    args+=("${rargs[@]}")
  fi
  [ -n "$allow" ] && args+=(--allow "$allow")

  log "queue drain: spawning queued worker $id"
  "$here/spawn.sh" "${args[@]}" >> "$LOG" 2>&1 &
}

# --- Master-liveness alert (issue #15) -----------------------------------------
# wait_ready only ever polls a pane's CONTENT, so a dead/absent master window (the
# tmux session killed, the window closed, the pane's process gone) looks
# indistinguishable from "just busy": is_ready keeps returning false, the events
# get requeued, and the loop retries forever with nothing ever telling anyone the
# master is gone. Detect the window's existence directly and surface it via log()
# instead of silently requeuing — heartbeat has no other channel once the master
# itself is the thing that's dead.
master_window_alive() { # <session:window> -> 0 if that tmux window exists
  # issue #107: a bare `-t "$1"` matches by unambiguous PREFIX, so if $S's
  # session is gone but a longer-named live session happens to start with the
  # same prefix and has a window of the same name, capture-pane would silently
  # hit that OTHER session instead of failing -- and every caller below
  # (master_dead_alert/clear, then send_prompt) would act on it. Require the
  # exact session first, same guard require_session_exists() enforces for the
  # other write paths (send.sh/spawn.sh/ask.sh).
  session_exists "${1%%:*}" && tmux capture-pane -t "$1" -p >/dev/null 2>&1
}

# $STATE_DIR/.master-dead holds "<first-seen-ts>\n<last-alert-ts>" so the alert
# re-fires on an interval instead of firing exactly once (and getting missed) or
# spamming the log every tick.
master_dead_alert() { # <target> <now> <interval_s>
  local target="$1" now="$2" interval="$3"
  local mf="$STATE_DIR/.master-dead" first="$now" last=0
  if [ -f "$mf" ]; then
    { IFS= read -r first; IFS= read -r last; } < "$mf" || true
    : "${first:=$now}"; : "${last:=0}"
  fi
  if [ "$last" -eq 0 ] || [ "$((now - last))" -ge "$interval" ]; then
    log "ALERT: master window '$target' is not alive (down $((now - first))s); worker events cannot be delivered — attach tmux and re-run bootstrap.sh"
    last="$now"
  fi
  printf '%s\n%s\n' "$first" "$last" > "$mf"
}

# Drop the standing alert once the master window is back.
master_dead_clear() { rm -f "$STATE_DIR/.master-dead"; }

heartbeat_main() {
  local S="$SESSION_NAME"
  # $CONFIG (from lib.sh) honors ORCH_ROOT overrides, unlike a script-relative
  # path — needed so hermetic tests can point config at a temp dir.
  local normal idle events
  normal="$(jq -r '.intervals.normal_seconds // 20' "$CONFIG")"
  idle="$(jq -r '.intervals.idle_seconds // 60' "$CONFIG")"
  local master_alert_interval
  master_alert_interval="$(jq -r '.heartbeat.master_alert_interval_seconds // 60' "$CONFIG")"

  # Issue #122: events whose .event is on this list carry no decision (e.g.
  # subagent-done fires on every worker turn) and must not wake the master at
  # all. Read once here, like normal/idle above -- not per tick. Denylist,
  # never allowlist: an unrecognized/future event type is always actionable,
  # so a new event class can never go silently missing. Portable bash 3.2
  # array build (no mapfile/readarray), same pattern as merge.sh's
  # required_checks.
  local inject_denylist=() _idl_line
  while IFS= read -r _idl_line; do
    [ -n "$_idl_line" ] && inject_denylist+=("$_idl_line")
  done < <(jq -r '.heartbeat.inject_denylist // ["subagent-done"] | .[]' "$CONFIG" 2>/dev/null || true)

  # Issue #52 safety valve: pane_has_draft() is a best-effort heuristic, so a
  # single misdetection (or a genuinely long-lived operator draft) must never be
  # able to starve delivery forever. Once EITHER bound trips — N consecutive
  # draft-ticks or T seconds since the first one — force-deliver regardless.
  local max_draft_ticks max_draft_secs draft_requeue_count=0 draft_requeue_since=0
  max_draft_ticks="$(jq -r '.heartbeat.max_draft_requeue_ticks // 10' "$CONFIG")"
  max_draft_secs="$(jq -r '.heartbeat.max_draft_requeue_seconds // 300' "$CONFIG")"

  # Issue #91: read the self-update knobs ONCE here (like normal/idle above),
  # not per-tick — the loop below only needs a cheap mtime check, not a fresh
  # config read every 20s. `enabled` reads the raw value because jq's
  # `// default` treats literal `false` as absent (same trap update.sh's own
  # _cfg avoids); a config that can't be parsed at all fails closed (disabled).
  local upd_enabled=0 upd_interval_min=1440 upd_state _upd_e _upd_h
  if _upd_e="$(jq -r '.update.enabled' "$CONFIG" 2>/dev/null)"; then
    [ "$_upd_e" = "false" ] || upd_enabled=1
    _upd_h="$(jq -r '.update.interval_hours' "$CONFIG" 2>/dev/null)"
    case "$_upd_h" in ''|null|*[!0-9]*) ;; *) upd_interval_min=$(( _upd_h * 60 )) ;; esac
  fi

  : > "$INBOX"
  log "heartbeat start (session=$S)"

  while [ ! -f "$STATE_DIR/.stop" ]; do
    drain_queue_if_room

    # Issue #91: throttled (>=24h apart, see update.* in config.json), notify-only
    # self-update check. The default tick is 20s (~4,300/day), so most ticks
    # must cost NEXT TO NOTHING: `upd_enabled` is read once above (not here),
    # and when due, "due" itself is a single cheap `find -mmin` mtime check —
    # only when that says the window has actually elapsed do we pay for
    # forking the full update.sh (source lib.sh, config reads, network).
    # update.sh re-checks the throttle itself too (its own tests call
    # --daily-check directly, not through this loop, and must stay correct
    # standalone) — this is purely a cheap pre-filter, not a second source of
    # truth. Skipped under bats (same $BATS_TEST_FILENAME convention as
    # lib.sh's isolation guard): any test that sources/runs heartbeat_main
    # with a config carrying update.enabled=true (e.g. a fixture copied from
    # the real config.json) must never make a real network call.
    if [ "$upd_enabled" = 1 ] && [ -z "${BATS_TEST_FILENAME:-}" ]; then
      upd_state="$STATE_DIR/update-check.json"
      if [ ! -f "$upd_state" ] || [ -z "$(find "$upd_state" -mmin -"$upd_interval_min" 2>/dev/null)" ]; then
        "$here/update.sh" --daily-check >/dev/null 2>&1 || true
      fi
    fi

    if master_window_alive "$S:$ORCH_WINDOW"; then
      master_dead_clear
    else
      master_dead_alert "$S:$ORCH_WINDOW" "$(date +%s)" "$master_alert_interval"
    fi

    if events="$(drain_inbox)"; then
      # Issue #122: decide noise-only-ness BEFORE anything else in this
      # branch -- before master_window_alive/wait_ready and before the
      # draft-requeue safety valve. Filtering later would still pay the 45s
      # wait_ready wait every tick, and a requeued noise batch could trip the
      # issue #52 safety valve and force-deliver the noise anyway (symptom
      # gone, defect alive).
      local noise_only=1 _dl_ev_line _dl_ev_type _dl_hit _dl
      if [ "${#inject_denylist[@]}" -eq 0 ]; then
        noise_only=0
      else
        while IFS= read -r _dl_ev_line; do
          [ -n "$_dl_ev_line" ] || continue
          # Fail open: unparseable JSON or a missing/empty .event field makes
          # the whole batch actionable rather than silently swallowing it.
          _dl_ev_type="$(jq -r '.event // empty' <<<"$_dl_ev_line" 2>/dev/null)" || { noise_only=0; break; }
          [ -n "$_dl_ev_type" ] || { noise_only=0; break; }
          _dl_hit=0
          for _dl in "${inject_denylist[@]}"; do
            [ "$_dl_ev_type" = "$_dl" ] && { _dl_hit=1; break; }
          done
          [ "$_dl_hit" -eq 1 ] || { noise_only=0; break; }
        done <<<"$events"
      fi

      if [ "$noise_only" -eq 1 ]; then
        # Every line matched heartbeat.inject_denylist on the .event FIELD
        # (never a raw-line substring -- a denylisted name appearing only in
        # another event's free-text `reason`, e.g. merge.sh's merge-blocked,
        # must never suppress that event). Drop the batch: no send_prompt, no
        # requeue. events.jsonl already has the full record (every emitter
        # dual-writes it); this only decides what gets injected.
        log "noise-only batch, suppressing wake: $(echo "$events" | tr '\n' ' ')"
      elif ! master_window_alive "$S:$ORCH_WINDOW"; then
        # Master window is gone outright — wait_ready would just poll a dead
        # target until its own timeout every tick. Requeue and move on instead
        # of burning that timeout; master_dead_alert above already surfaced it.
        printf '%s\n' "$events" >> "$INBOX"
        log "master window down; requeued events"
      # Only poke the master when ITS pane is idle, to avoid prompt collisions.
      elif ! wait_ready "$S:$ORCH_WINDOW" 45; then
        # Master busy — requeue and try again next tick.
        printf '%s\n' "$events" >> "$INBOX"
        log "master busy; requeued events"
      else
        # Issue #38: an idle-looking input box can still hold the operator's
        # unsent draft. Injecting here would paste into it and submit it via the
        # Enter in send_prompt, wiping the draft. Requeue instead of injecting —
        # never clear the line — and retry next tick. But (issue #52) never do
        # that forever: force-deliver once the safety valve trips.
        local force_deliver=0 elapsed=0
        if pane_has_draft "$S:$ORCH_WINDOW"; then
          draft_requeue_count=$((draft_requeue_count + 1))
          [ "$draft_requeue_since" -gt 0 ] || draft_requeue_since="$(date +%s)"
          elapsed=$(( $(date +%s) - draft_requeue_since ))
          if [ "$draft_requeue_count" -ge "$max_draft_ticks" ] || [ "$elapsed" -ge "$max_draft_secs" ]; then
            force_deliver=1
            log "draft safety valve tripped (ticks=$draft_requeue_count elapsed=${elapsed}s >= ticks_cap=$max_draft_ticks/secs_cap=$max_draft_secs); forcing delivery"
          fi
        else
          force_deliver=1
        fi

        if [ "$force_deliver" -eq 1 ]; then
          draft_requeue_count=0
          draft_requeue_since=0
          send_prompt "$S:$ORCH_WINDOW" "[orchestrator heartbeat] Worker events since last check:
$events

Read _orch/state/workers/*.json, then decide and dispatch next steps (assign, review, or shut down). If you're at all unsure of current orchestration state (e.g. right after a compaction), run $here/rehydrate.sh first."
          log "woke master with: $(echo "$events" | tr '\n' ' ')"
        else
          printf '%s\n' "$events" >> "$INBOX"
          log "master has an unsent draft; requeued events (${draft_requeue_count}/${max_draft_ticks})"
        fi
      fi
      sleep "$normal"
    else
      sleep "$idle"
    fi
  done
  log "heartbeat stop"
}

# Run the loop only when executed directly. When sourced (e.g. by hermetic bats
# tests) this exposes inbox_swap/drain_inbox without starting the loop.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_valid_session_name
  heartbeat_main
fi
