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

  # issue #148: launch against the repo the spawn was queued for, not the
  # heartbeat's own PROJECT_ROOT, and carry the queue-time unrelated-repo override.
  # Records queued before #148 carry neither field: old behaviour.
  # A post-#148 record states the override exactly (empty = none), so the
  # heartbeat's own ORCH_ALLOW_UNRELATED_REPO must not leak into its spawn.
  local target unrel has_unrel
  target="$(jq -r '.target_repo // empty' <<<"$item")"
  unrel="$(jq -r '.allow_unrelated // empty' <<<"$item")"
  has_unrel="$(jq -r 'has("allow_unrelated")' <<<"$item")"
  log "queue drain: spawning queued worker $id${target:+ (target repo $target)}"
  (
    [ -z "$target" ] || export PROJECT_ROOT="$target"
    [ "$has_unrel" != "true" ] || unset ORCH_ALLOW_UNRELATED_REPO
    [ -z "$unrel" ] || export ORCH_ALLOW_UNRELATED_REPO="$unrel"
    "$here/spawn.sh" "${args[@]}" >> "$LOG" 2>&1 && exit 0
    # spawn.sh can refuse before writing any status (target repo vanished, guard 0
    # unrelated-repo refusal, duplicate window, ...). The queue record is already
    # popped, so a worker still reading "queued" (or with no status file at all)
    # here would stay queued/invisible forever.
    case "$(_worker_status "$id")" in queued | "") ;; *) exit 0 ;; esac
    _drain_spawn_failed "$id" "$target" "$model" "$task"
  ) &
}

# _drain_spawn_failed <id> <target> <model> <task>: mark a queued worker whose drained
# spawn was refused as spawn-failed and notify the master the same way spawn.sh does.
# `updated` is bumped so the reaper's retention counts from the failure, not from
# queue time; model/task/created are seeded from the queue record only when the
# status file lacks them (e.g. it was removed while queued), so `orch status` rows
# don't render as null.
_drain_spawn_failed() {
  local id="$1" target="$2" model="$3" task="$4" sf_line
  log "queue drain: spawn.sh refused queued worker $id${target:+ (target repo $target)}; marking spawn-failed"
  # shellcheck disable=SC2016  # $i/$u/$r/$m/$t are jq --arg vars, not shell
  update_worker_status "$id" --arg i "$id" --arg u "$(date -u +%FT%TZ)" --arg r "$target" \
    --arg m "$model" --arg t "$task" \
    '.id=$i | .status="spawn-failed" | .updated=$u | .created //= $u | .model //= $m | .task //= $t
     | (if $r == "" then . else .target_repo=$r end)' || true
  sf_line="$(printf '{"id":"%s","event":"spawn-failed","ts":"%s"}' "$id" "$(date -u +%FT%TZ)")"
  printf '%s\n' "$sf_line" >> "$INBOX"
  printf '%s\n' "$sf_line" >> "$STATE_DIR/events.jsonl"
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

# --- Master context reset (issue #160, part B of #158) ------------------------
# The master's context only grows. When master-context.json (written by the
# status line, #159) says it is too full, heartbeat -- the master's single prompt
# injector (#55 keeps the watchdog out) -- asks it to checkpoint master-notes.md,
# then /clear's it; the SessionStart hook re-injects role prompt + rehydrate.
# Thresholds scale with the window the master actually has (.window), so 200k and
# 1M masters both reset at a sensible point; an unknown window never resets.

# Pure decision: no tmux, no file IO. Returns 0 only when a reset is due.
# <ctx_json> <session_json> <now> <last_reset_json> <pct> <fraction> <cooldown> [enabled]
# pct/fraction/cooldown/enabled fall back to 60 / 0.35 / 1800 / true when empty
# (a missing master_context block). A reading needs numeric tokens: a pct-only
# record (current_usage null, just after /clear or a compaction) can carry a
# stale pct. Freshness is session-id equality, not a
# timestamp: the status line goes quiet when idle and may not re-run after /clear.
master_reset_due() {
  local ctx="$1" sess="$2" now="$3" last="${4:-}" pct="${5:-}" frac="${6:-}" cool="${7:-}" enabled="${8:-}"
  [ "$enabled" = "false" ] && return 1
  [ -n "$last" ] || last='{}'
  jq -ne --argjson ctx "${ctx:-null}" --argjson sess "${sess:-null}" --argjson last "$last" \
    --argjson now "$now" --argjson pct "${pct:-60}" --argjson frac "${frac:-0.35}" \
    --argjson cool "${cool:-1800}" '
    ($ctx // {}) as $c | ($sess // {}) as $s |
    ($c.window // 0) as $w |
    ($c.session_id // "") as $cid |
    ($last.backoff // false) != true
    and $cid != "" and $cid == ($s.session_id // "")
    and ($w | type == "number") and $w > 0
    and ($c.tokens | type == "number")
    and ((($c.pct // 0) >= $pct) or (($c.cumulative // false) != true and ($c.tokens // 0) >= ($frac * $w)))
    and ($now - ($last.ts // 0)) >= $cool' >/dev/null 2>&1
}

# Atomically replace master-reset.json with stdin.
_master_reset_write() {
  local tmp="$STATE_DIR/master-reset.json.tmp.$$"
  # -s: a failed upstream jq must not clobber the file with nothing.
  cat > "$tmp" && [ -s "$tmp" ] && mv -f "$tmp" "$STATE_DIR/master-reset.json" || rm -f "$tmp"
}

# Loop guard: the first reading from the post-reset session that is still over
# threshold means the floor (CLAUDE.md + rehydrate + notes) is itself too big.
# Latch backoff=true (log once) until `orch up` clears master-reset.json.
# Judges .first (the status line's first reading of that session), not the
# current one: by the time this tick runs the resumed master may already have
# grown well past its floor. Falls back to the current reading if absent.
# Like master_reset_due, a reading needs numeric tokens: a pct-only record
# (current_usage null right after /clear) can carry a stale pct, which would
# latch a spurious backoff -- or "verify" a floor that was never measured.
master_reset_guard() { # <ctx_json> <last_json> <pct> <fraction>
  local ctx="$1" last="$2" pct="${3:-60}" frac="${4:-0.35}" verdict judged
  [ -n "$last" ] || return 0
  verdict="$(jq -nr --argjson c "${ctx:-null}" --argjson l "$last" --argjson pct "${pct:-60}" --argjson frac "${frac:-0.35}" '
    ($c // {}) as $c0 | ($c0 + ($c0.first // {})) as $c |
    if ($l.backoff // false) == true or ($l.verified // false) == true then "skip"
    elif ($l.old_session_id // "") == "" or ($c.session_id // "") == "" or $c.session_id == $l.old_session_id then "skip"
    elif (($c.window // 0) | type != "number") or ($c.window // 0) <= 0 then "skip"
    elif ($c.tokens | type) != "number" then "skip"
    elif (($c.pct // 0) >= $pct) or (($c.cumulative // false) != true and ($c.tokens // 0) >= ($frac * $c.window)) then "backoff"
    else "ok" end' 2>/dev/null)" || return 0
  case "$verdict" in
    backoff)
      jq -c '.backoff = true' <<<"$last" | _master_reset_write
      # Report the reading that was judged (.first), not the current one.
      judged="$(jq -r '(. + (.first // {})) | "pct=\(.pct) tokens=\(.tokens)"' <<<"$ctx" 2>/dev/null)"
      log "master context reset loop: first post-reset reading is still over threshold ($judged); the context floor is too large -- automatic resets disabled until 'orch up'"
      ;;
    ok)
      jq -c '.verified = true' <<<"$last" | _master_reset_write
      ;;
  esac
  return 0
}

# One tick of the reset machinery. Never forces: any doubt aborts without /clear.
# $STATE_DIR/master-reset-retry-after (epoch) throttles retries after a
# post-checkpoint abort; a file, not a variable, so `orch up` can clear it.
# $_MASTER_RESET_CFG caches the master_context knobs: read once, not per tick
# (same convention as heartbeat_main's other knobs).
_MASTER_RESET_CFG=""
# Dual-write an event to events.jsonl AND the inbox (like every other emitter),
# so the heartbeat's normal delivery path -- busy/draft guards included --
# wakes the master with it.
_master_reset_event() { # <event> [old_session_id]
  local line
  line="$(jq -nc --arg e "$1" --arg ts "$(date -u +%FT%TZ)" --arg o "${2:-}" '{id:"master",event:$e,old_session_id:$o,ts:$ts}')" || return 0
  printf '%s\n' "$line" >> "$STATE_DIR/events.jsonl"
  printf '%s\n' "$line" >> "$INBOX"
}
# Abort without /clear: log, throttle retries by the cooldown, tell the master.
_master_reset_abort() { # <log message> <old_session_id> <cooldown>
  log "$1"
  printf '%s\n' "$(( $(date +%s) + ${3:-1800} ))" > "$STATE_DIR/master-reset-retry-after"
  _master_reset_event master-reset-aborted "$2"
}
master_reset_tick() { # <session:window>
  local target="$1" ctx sess last cfg enabled pct frac cool cptimeout now retry_after
  ctx="$(cat "$STATE_DIR/master-context.json" 2>/dev/null || true)"
  [ -n "$ctx" ] || return 0
  sess="$(cat "$STATE_DIR/master-session.json" 2>/dev/null || true)"
  last="$(cat "$STATE_DIR/master-reset.json" 2>/dev/null || true)"
  if [ -z "$_MASTER_RESET_CFG" ]; then
    _MASTER_RESET_CFG="$(jq -r '.master_context // {} | [(if .enabled == false or .enabled == "false" then "false" else "true" end), (.reset_pct // ""), (.reset_fraction // ""), (.cooldown_s // ""), (.checkpoint_timeout_s // "")] | map(tostring) | join("|")' "$CONFIG" 2>/dev/null)" || { _MASTER_RESET_CFG=""; return 0; }
  fi
  cfg="$_MASTER_RESET_CFG"
  IFS='|' read -r enabled pct frac cool cptimeout <<<"$cfg"
  [ "$enabled" = "false" ] && return 0
  # A non-numeric knob would make every --argjson below fail, i.e. resets
  # silently off. Say so once and stay off.
  local _k
  for _k in "$pct:f" "$frac:f" "$cool:i" "$cptimeout:p"; do
    case "$_k" in
      *:f) _k="${_k%:f}"; [[ -z "$_k" || ( "$_k" =~ ^[0-9]+(\.[0-9]+)?$ && "$_k" =~ [1-9] ) ]] && continue ;; # 0 = always due
      *:i) _k="${_k%:i}"; [[ -z "$_k" || "$_k" =~ ^[0-9]+$ ]] && continue ;;   # bash -lt needs integers
      *:p) _k="${_k%:p}"; [[ -z "$_k" || "$_k" =~ ^[1-9][0-9]*$ ]] && continue ;; # 0 = abort every time
    esac
    log "master_context: invalid setting '$_k' in config.json -- automatic master resets disabled"
    _MASTER_RESET_CFG="false||||"
    return 0
  done
  master_reset_guard "$ctx" "$last" "$pct" "$frac"
  last="$(cat "$STATE_DIR/master-reset.json" 2>/dev/null || true)"
  now="$(date +%s)"
  retry_after="$(cat "$STATE_DIR/master-reset-retry-after" 2>/dev/null || true)"
  case "$retry_after" in ''|*[!0-9]*) retry_after=0 ;; esac
  [ "$now" -ge "$retry_after" ] || return 0
  master_reset_due "$ctx" "${sess:-null}" "$now" "$last" "$pct" "$frac" "$cool" "$enabled" || return 0
  wait_ready "$target" 2 || return 0
  pane_has_draft "$target" && return 0

  cptimeout="${cptimeout:-300}"
  local t0 token cpct ctok old_sid notes="$STATE_DIR/master-notes.md" ok=0 why=""
  cpct="$(jq -r '.pct' <<<"$ctx")"; ctok="$(jq -r '.tokens' <<<"$ctx")"
  old_sid="$(jq -r '.session_id' <<<"$ctx")"
  # Completion = the notes contain this tick's one-off token. An mtime check
  # can't tell the checkpoint from a routine notes refresh (or a write from the
  # master's previous turn in the same second): either would let /clear wipe
  # a context whose plan was never written down.
  t0="$(date +%s)"
  token="orch-checkpoint-$t0-$$-$RANDOM"
  # orch down kills the heartbeat (TERM) rather than waiting for .stop: still
  # tell the master, which was just told to stop, that no reset is coming.
  # A TERM mid-send_prompt is deferred until the paste and its Enter are both
  # in, so it can never leave the checkpoint text unsent in the input row.
  local _mr_term=0
  trap '_mr_term=1' TERM
  send_prompt "$target" "[orchestrator heartbeat] Your context is nearly full and will be cleared automatically. Rewrite $notes with your current plan and any in-flight operation (what is running, what you were about to do next), end it with the line: $token -- then stop. Do not start new work. (If the reset is aborted you will get a master-reset-aborted event: then carry on normally.)"
  trap '_master_reset_event master-reset-aborted "$old_sid"; exit 143' TERM
  [ "$_mr_term" -eq 0 ] || { _master_reset_event master-reset-aborted "$old_sid"; exit 143; }
  log "master context over threshold (pct=$cpct tokens=$ctok); checkpoint requested"
  while [ "$(( $(date +%s) - t0 ))" -lt "$cptimeout" ]; do
    # This wait blocks the heartbeat loop: honour .stop and a dead master.
    [ -e "$STATE_DIR/.stop" ] && { why="heartbeat stopping"; break; }
    master_window_alive "$target" || { why="master window gone"; break; }
    if grep -qF "$token" "$notes" 2>/dev/null && is_ready "$target"; then ok=1; break; fi
    sleep 1
  done
  if [ -n "$why" ]; then :
  elif [ "$ok" -ne 1 ]; then why="checkpoint not completed within ${cptimeout}s"
  elif pane_has_draft "$target"; then why="draft appeared"
  else
    # One is_ready sample can catch a transient frame between tool calls of a
    # turn that is still running; /clear typed then lands mid-turn. Settle and
    # re-confirm idle (and still no draft) right before sending it.
    sleep 1
    if ! is_ready "$target"; then why="master busy again before /clear"
    elif pane_has_draft "$target"; then why="draft appeared"; fi
  fi
  # Defer TERM again until the abort event is written, or the reset record and
  # the whole /clear send (paste AND its Enter) are in: a TERM landing mid-send
  # would otherwise leave '/clear' typed but unsubmitted in the master's input.
  _mr_term=0
  trap '_mr_term=1' TERM
  if [ -n "$why" ]; then
    # The master was told to stop; tell it the reset is off so it resumes.
    _master_reset_abort "master reset aborted: $why (no /clear sent)" "$old_sid" "$cool"
    trap - TERM
    [ "$_mr_term" -eq 0 ] || exit 143
    return 0
  fi
  # Record the reset BEFORE sending /clear: orch down (stop.sh) touches .stop
  # and TERMs us at once, and TERM is not trapped after the send, so a record
  # written any later (after the confirm loop or the ready-wait) is lost when
  # the TERM lands in between -- and with it the loop guard's and cooldown's
  # only record of a /clear that really happened. If the /clear never takes,
  # the unconfirmed path below overwrites this with a backoff latch.
  jq -nc --argjson ts "$(date +%s)" --arg o "$old_sid" --argjson p "${cpct:-null}" --argjson t "${ctok:-null}" \
    '{ts:$ts, old_session_id:$o, pct:$p, tokens:$t}' | _master_reset_write
  send_prompt "$target" "/clear"
  trap - TERM
  # A deferred TERM: the record above is kept (unjudged) by the next `orch up`.
  [ "$_mr_term" -eq 0 ] || exit 143
  # Confirm it took: the SessionStart hook records the new session_id on every
  # /clear. If it never changes, the /clear did not happen (not submitted, or
  # swallowed) -- do not claim a reset or tell the master it was cleared.
  # Independent of checkpoint_timeout_s; env override is for hermetic tests.
  local new_sid="" i=0 confirm_s="${ORCH_MASTER_CLEAR_CONFIRM_S:-45}"
  case "$confirm_s" in ''|*[!0-9]*) confirm_s=45 ;; esac
  # Read the session id at least once before honouring .stop: a stop that lands
  # right after /clear must not skip the check and report a /clear that took as
  # unconfirmed.
  while :; do
    new_sid="$(jq -r '.session_id // empty' "$STATE_DIR/master-session.json" 2>/dev/null || true)"
    [ -n "$new_sid" ] && [ "$new_sid" != "$old_sid" ] && break
    new_sid=""
    { [ "$i" -lt "$confirm_s" ] && [ ! -e "$STATE_DIR/.stop" ]; } || break
    sleep 1; i=$((i+1))
  done
  if [ -z "$new_sid" ]; then
    # Latch backoff: either '/clear' is sitting unsent in the input row (the
    # operator must look; retrying would stack more text on it), or the
    # SessionStart hook is not recording sessions -- then clears are real but
    # invisible to the loop guard, and retrying every cooldown would be an
    # unguarded reset loop. Both need a human; `orch up` re-arms.
    jq -nc --argjson ts "$(date +%s)" --arg o "$old_sid" \
      '{ts:$ts, old_session_id:$o, backoff:true, unconfirmed:true}' | _master_reset_write
    local why_unconf="session id unchanged after /clear ('/clear' may be unsent in the master's input, or the SessionStart hook is not recording)"
    [ -e "$STATE_DIR/.stop" ] && why_unconf="heartbeat stopping before the session id changed (the /clear may still take)"
    _master_reset_abort "master reset unconfirmed: $why_unconf -- automatic resets disabled until 'orch up'" "$old_sid" "$cool"
    return 0
  fi
  wait_ready "$target" 45 || log "master not ready 45s after /clear"
  log "master context reset (pct=$cpct tokens=$ctok)"
  # Also wakes the freshly cleared master (via the inbox) so it resumes the
  # in-flight work its rehydrated notes describe instead of idling until the
  # next worker event.
  _master_reset_event master-reset "$old_sid"
}

# Issue #178 (#152 direction 2): backstop for Bash-made writes into the target
# repo's main checkout, which the PreToolUse guard cannot see. One call = one tick.
# Per distinct target_repo with >=1 live mode:"worktree" worker, run ONE
# `git status --porcelain` and alert on entries absent from the union of those
# workers' spawn-time baselines (so an operator edit made between two spawns is
# not blamed). Bash writes cannot be attributed: the event lists the live worker
# ids without claiming which one wrote. A repo where any such worker lacks a
# baseline (spawned before this existed) is skipped rather than guessed at.
# Every dirty path seen (reported OR baseline-absorbed) is persisted per repo so a
# second tick is silent, and so a path absorbed by a later worker's baseline is not
# reported once that worker leaves the live set; an entry that clears and returns
# re-alerts (a baseline path seen clean is dropped from its baseline too). Entries
# compare by path, so a write to a path still dirty since the baseline is not seen. Known limitation: a Bash `git commit` /
# `checkout` into the root leaves it clean and is NOT detected (a HEAD comparison
# would false-positive on an operator `git pull`).
root_dirty_tick() {
  shopt -s nullglob
  local f st mode repo id real
  local pairs="" repos="" keep=" " wins="" wins_read=0 gc=1 bf
  for f in "$WORKERS_DIR"/*.json; do
    IFS=$'\037' read -r st mode repo id < <(jq -r '[.status // "", .mode // "", .target_repo // "", .id // ""] | join("\u001f")' "$f" 2>/dev/null) || continue
    # dead: watchdog confirmed the window is gone, so it can write nothing.
    case "$st" in spawn-failed|queued|dead|"") continue ;; esac
    [ "$mode" = worktree ] && [ -n "$repo" ] || continue
    [ -n "$id" ] || id="$(basename "$f" .json)"
    # A worker is live iff its window exists, whatever its status says: report.sh
    # writes "done" (merged/blocked likewise) at the end of EVERY turn and send.sh
    # never resets it, so a follow-up turn still reads "done"; and a needs-input
    # worker whose window was closed is never marked dead (dead_sweep only handles
    # mid-turn statuses), so trusting the status would keep it "live" forever.
    # One list-windows per tick, only once a worktree worker is seen. If the
    # session can't be listed, skip the whole tick: treating every worker as gone
    # would wipe the reported records below and re-alert them next tick.
    if [ "$wins_read" = 0 ]; then
      wins_read=1
      session_exists "$SESSION_NAME" || return 0
      wins="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null)" || return 0
    fi
    printf '%s\n' "$wins" | grep -qxF -- "$id" || continue
    # A live worker's repo that is momentarily unreachable (unmounted network FS)
    # is skipped, but its record must survive the GC below or every path already
    # reported re-alerts once the repo is back.
    [ -d "$repo" ] || { gc=0; continue; }
    real="$(_phys_dir "$repo")" || real="$repo"
    pairs+="$real"$'\t'"$id"$'\n'
  done
  [ -n "$pairs" ] && repos="$(printf '%s' "$pairs" | cut -f1 | sort -u)"
  local all cur new bl union bfs bk rep_f paths wl ev wids
  [ -z "$repos" ] || mkdir -p "$STATE_DIR/root-dirty"
  while IFS= read -r real; do
    [ -n "$real" ] || continue
    rep_f="$STATE_DIR/root-dirty/$(_orch_session_hash "$real")"
    keep+="${rep_f##*/} "
    wids="$(printf '%s' "$pairs" | awk -F'\t' -v r="$real" '$1==r{print $2}')"
    bfs=""; bl=1
    while IFS= read -r id; do
      f="$(root_baseline_file "$real" "$id")"
      [ -f "$f" ] || { bl=0; break; }
      bfs+="$f"$'\n'
    done <<<"$wids"
    [ "$bl" = 1 ] || continue
    # Compare PATHS, not whole porcelain lines: an operator `git add` turns a
    # baseline " M f" into "M  f" and must not be blamed on a worker.
    # A failed `git status` must not overwrite the record with "nothing dirty":
    # the next good tick would re-alert every entry already reported.
    cur="$(root_porcelain "$real")" || continue
    # all = every dirty path now; it becomes the record. Recording only the
    # reported (post-union) paths would let an operator edit masked by a later
    # worker's baseline alert as soon as that worker's window closes.
    all="$(printf '%s\n' "$cur" | cut -c4- | grep -v '^$' || true)"
    # A baseline absorbs only dirt that predates its worker: once a baseline path
    # is seen clean, drop it from that baseline, so a later write to it is reported
    # instead of being masked for the rest of the worker's life.
    union=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      bf="$(cat "$f")"
      bk="$(awk 'NR==FNR{d[$0];next} (substr($0,4) in d)' <(printf '%s\n' "$all") - <<<"$bf" 2>/dev/null)" || bk="$bf"
      if [ "$bk" != "$bf" ]; then
        { [ -z "$bk" ] || printf '%s\n' "$bk"; } > "$f.tmp" && mv -f "$f.tmp" "$f"
      fi
      union+="$(printf '%s\n' "$bk" | cut -c4- | grep -v '^$' || true)"$'\n'
    done <<<"$bfs"
    union="$(printf '%s' "$union" | grep -v '^$' || true)"
    # Never hand grep an empty pattern (an empty union / record): BSD grep can
    # treat an empty pattern as matching every line, even under -x.
    cur="$all"
    [ -z "$union" ] || cur="$(printf '%s\n' "$all" | grep -vxFf <(printf '%s\n' "$union") || true)"
    new="$cur"
    if [ -n "$cur" ] && [ -s "$rep_f" ]; then
      new="$(printf '%s\n' "$cur" | grep -vxFf "$rep_f" || true)"
    fi
    [ -n "$new" ] || { printf '%s' "$all" > "$rep_f"; continue; }
    # Capped: the event is pasted into the master's pane, and one `npm install` or
    # build into an unignored root dir lists thousands of files under -uall.
    paths="$(printf '%s\n' "$new" | jq -Rsc 'split("\n") | map(select(. != ""))')"
    wl="$(printf '%s\n' "$wids" | jq -Rsc 'split("\n") | map(select(. != ""))')"
    ev="$(jq -nc --arg r "$real" --arg ts "$(date -u +%FT%TZ)" --argjson p "$paths" --argjson w "$wl" \
      '{id:"heartbeat",event:"root-dirty",repo:$r,paths:$p[:50],paths_total:($p|length),workers:$w,ts:$ts,
        note:"a worktree worker (one of \($w|join(", "))) may have written the main checkout via Bash"}')" || continue
    printf '%s\n' "$ev" >> "$STATE_DIR/events.jsonl"
    printf '%s\n' "$ev" >> "$INBOX"
    # Record only once the event is out: a failed event build above leaves the
    # record untouched so the next tick retries instead of silently dropping it.
    printf '%s' "$all" > "$rep_f"
    log "root-dirty: new entries in $real while worktree workers live: $(jq -r '.paths_total|tostring' <<<"$ev") path(s): $(jq -r '.paths|join(" ")' <<<"$ev")"
  done <<<"$repos"
  # Forget reported entries of repos with no live worktree worker: a stale record
  # would silence a later worker re-dirtying the same path after it was reverted.
  [ "$gc" = 1 ] || return 0
  for f in "$STATE_DIR"/root-dirty/*; do
    case "$keep" in *" ${f##*/} "*) ;; *) rm -f "$f" ;; esac
  done
  return 0
}
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
  # so a new event class can never go silently missing. Kept as a compact
  # JSON array of non-empty strings for the single-pass jq filter in the loop
  # below (one fork per tick, not one per event line); an unreadable config
  # or a non-iterable value (e.g. a bare string) yields '[]' (filtering off,
  # full-fidelity delivery) and is logged so the misconfig is visible.
  local inject_denylist_json
  inject_denylist_json="$(jq -c '[.heartbeat.inject_denylist // ["subagent-done"] | .[] | tostring | select(. != "")]' "$CONFIG" 2>/dev/null)" \
    || { inject_denylist_json='[]'; log "heartbeat.inject_denylist unreadable or not an array; denylist filtering disabled"; }
  [ -n "$inject_denylist_json" ] || inject_denylist_json='[]'

  # Issue #52 safety valve: pane_has_draft() is a best-effort heuristic, so a
  # single misdetection (or a genuinely long-lived operator draft) must never be
  # able to starve delivery forever. Once EITHER bound trips — N consecutive
  # draft-ticks or T seconds since the first one — force-deliver regardless.
  local max_draft_ticks max_draft_secs draft_requeue_count=0 draft_requeue_since=0 hb_wr=0
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
      master_reset_tick "$S:$ORCH_WINDOW"
      root_dirty_tick
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
      local noise_only=1 kept
      if [ "$inject_denylist_json" = '[]' ]; then
        noise_only=0
      else
        # Issue #163 part B: one jq pass emits a keep(1)/drop(0) flag per
        # line; a line is dropped only when its .event FIELD is denylisted.
        # Fail open: a line that is not exactly one JSON object with a
        # non-empty string .event (unparseable, concatenated values,
        # missing/empty .event) is kept rather than silently swallowed;
        # whitespace-only lines carry nothing and are dropped. Kept lines are
        # copied from $events itself, never from jq's output (jq -R rewrites
        # invalid UTF-8). If jq fails or its flag count does not match the
        # line count, the whole batch is kept.
        local _dl_flags _dl_line _dl_flag _dl_n=0 _dl_lines=0
        kept=""
        if _dl_flags="$(jq -Rr --argjson dl "$inject_denylist_json" '
          if test("\\S") | not then 0
          else (try (fromjson | .event) catch null) as $e
            | if ($e | type) == "string" and $e != "" and any($dl[]; . == $e)
              then 0 else 1 end
          end' <<<"$events" 2>/dev/null)"; then
          while IFS= read -r _dl_line <&3 && IFS= read -r _dl_flag <&4; do
            _dl_n=$((_dl_n + 1))
            [ "$_dl_flag" = 0 ] || kept+="${kept:+$'\n'}$_dl_line"
          done 3<<<"$events" 4<<<"$_dl_flags"
          # Line count without forking (printf|wc|tr every tick): newlines + 1.
          _dl_lines="${events//[!$'\n']/}"
          _dl_lines=$(( ${#_dl_lines} + 1 ))
          [ "$_dl_n" -eq "$_dl_lines" ] || { kept="$events"; log "denylist filter: flag/line count mismatch ($_dl_n/$_dl_lines); delivering batch unfiltered"; }
        else
          kept="$events"
          log "denylist filter: jq failed; delivering batch unfiltered"
        fi
        # A mixed batch is injected (and requeued) with the denylisted lines
        # stripped; events.jsonl keeps the full record.
        [ -z "$kept" ] || { noise_only=0; events="$kept"; }
      fi

      if [ "$noise_only" -eq 1 ]; then
        # Every non-blank line matched heartbeat.inject_denylist on the .event FIELD
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
      # issue #155: a dialog (already up, or rendering mid-wait) ends the wait at
      # once -- is_ready refuses dialogs, so a plain wait_ready would burn its
      # whole 45s every tick on a dialog that never clears by itself.
      elif hb_wr=0; wait_ready_or_dialog "$S:$ORCH_WINDOW" 45 || hb_wr=$?; [ "$hb_wr" -ne 0 ]; then
        # Master busy or on a dialog — requeue and try again next tick.
        printf '%s\n' "$events" >> "$INBOX"
        if [ "$hb_wr" -eq 2 ]; then log "master showing a dialog; requeued events"
        else log "master busy; requeued events"; fi
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
