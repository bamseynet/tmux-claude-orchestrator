#!/usr/bin/env bash
# _orch/lib.sh — shared helpers. Source this; do not execute directly.
# Provides: paths, log(), strip_ansi(), pane_tail(), is_busy(), is_ready(),
#           wait_ready(), send_prompt(), spawn-injection guards
#           pane_has_welcome(), pane_active(), inject_confirmed(), confirm_inject(),
#           locked worker-status writers: write_worker_status(), update_worker_status(),
#           and the resource guard: live_worker_count(), free_mem_mb(),
#           spend_count(), est_spend_usd(), record_spend(), check_spawn_gate(),
#           queue_push(), queue_pop().

# Resolve toolkit root (parent of _orch/) from this file's location.
ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ORCH_DIR="$ORCH_ROOT/_orch"
STATE_DIR="$ORCH_DIR/state"
WORKERS_DIR="$STATE_DIR/workers"
INBOX="$STATE_DIR/inbox.jsonl"
LOG="$STATE_DIR/orch.log"
CONFIG="$ORCH_DIR/config.json"
QUEUE="$STATE_DIR/queue.jsonl"
SPEND_FILE="$STATE_DIR/spend.json"

mkdir -p "$WORKERS_DIR"

: "${SESSION_NAME:=orch}"      # tmux session name
: "${ORCH_WINDOW:=orchestrator}"  # master window name

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# Strip ANSI/OSC/charset escapes. Uses perl (present on macOS by default) because
# BSD sed does not handle \x1b hex escapes reliably.
strip_ansi() {
  perl -pe '
    s/\x1b\[[0-9;:?<=>]*[a-zA-Z]//g;
    s/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)//g;
    s/\x1b[()][0-9A-Za-z]//g;
    s/[\x0e\x0f]//g;
  '
}

# Last N lines of a pane, de-ANSI'd.
pane_tail() { # <target> [lines]
  tmux capture-pane -t "$1" -p 2>/dev/null | tail -n "${2:-15}" | strip_ansi
}

# --- TUI match patterns (issue #12) -------------------------------------------------
# Every regex used to read the Claude Code TUI's pane state is centralized here,
# sourced from _orch/config.json's `tui_patterns` block, so a future Claude Code UI
# change is a one-line config edit instead of a code change. Defaults below (used
# when config.json is missing the block, e.g. in older checkouts) match the
# patterns this file shipped with historically.
_tui_pattern() { # <key> <default>
  local v
  v="$(jq -r ".tui_patterns.$1 // empty" "$CONFIG" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}
TUI_BUSY_REGEX="$(_tui_pattern busy_regex 'esc to interrupt|Running…|Compacting')"
# Deliberately excludes the "●" busy dot: it also appears in idle output (e.g. a
# status-line mode indicator), so matching it here caused inject_confirmed to
# report a dropped task as landed (issue #12). Only the animated spinner frames,
# which are exclusive to an active turn, count as an activity glyph.
TUI_ACTIVE_GLYPH_REGEX="$(_tui_pattern active_glyph_regex '✻|✽|✳|✶')"
TUI_READY_REGEX="$(_tui_pattern ready_regex '│ *>|❯|for shortcuts|Try "')"
TUI_WELCOME_REGEX="$(_tui_pattern welcome_regex 'Welcome')"
TUI_INPUT_GLYPH_REGEX="$(_tui_pattern input_glyph_regex '│ *>|❯')"

# Busy if Claude Code is mid-turn. The strongest, most version-stable signal is the
# "esc to interrupt" hint it shows while working. TUNE HERE if a future TUI changes it.
is_busy() { # <target>  -> 0 if busy
  pane_tail "$1" 15 | grep -qiE "$TUI_BUSY_REGEX"
}

# Ready if not busy AND the input prompt box is visible.
is_ready() { # <target>  -> 0 if idle & ready for input
  is_busy "$1" && return 1
  pane_tail "$1" 15 | grep -qE "$TUI_READY_REGEX"
}

# Block until a pane is ready or timeout. Adds a short settle after ready.
wait_ready() { # <target> [timeout_s]
  local t="${2:-60}" i=0
  while [ "$i" -lt "$t" ]; do
    if is_ready "$1"; then sleep 0.4; return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}

# Spawn-time injection guards. When a send lands before the REPL is truly ready it
# is silently lost and the worker sits idle at the startup screen. The startup
# "Welcome" banner scrolls away once a prompt is actually accepted, so its absence
# (or a live activity marker) is a robust "the task landed" signal.

# Startup "Welcome" banner still on screen? (0 = banner present)
pane_has_welcome() { pane_tail "$1" 25 | grep -qi "$TUI_WELCOME_REGEX"; }

# Pane shows live activity (spinner / interrupt hint)? (0 = active)
pane_active() { pane_tail "$1" 25 | grep -qE "$TUI_BUSY_REGEX|$TUI_ACTIVE_GLYPH_REGEX"; }

# An injected prompt appears to have landed. Requires positive evidence rather than
# defaulting to "landed" (issue #12): either the pane is actively working the task,
# or the startup banner has scrolled away AND the pane is back to a ready prompt
# (i.e. it landed and finished fast). Anything else — including "banner already
# gone but no activity and no ready prompt either" — is treated as NOT confirmed,
# so spawn.sh's retry/failure path can kick in instead of silently trusting it.
inject_confirmed() { # <target>  -> 0 if the injection looks accepted
  pane_active "$1" && return 0
  pane_has_welcome "$1" && return 1
  is_ready "$1" && return 0
  return 1
}

# Poll until an injected prompt is confirmed, or timeout. Never hangs.
confirm_inject() { # <target> [timeout_s]
  local t="${2:-15}" i=0
  while [ "$i" -lt "$t" ]; do
    inject_confirmed "$1" && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

# Deliver text into a pane reliably:
#  - load-buffer/paste-buffer handles multiline (send-keys breaks on newlines)
#  - a buffer name unique per call (target + pid + $RANDOM + a call counter) so two
#    concurrent sends to the same target (e.g. a watchdog nudge racing `orch send`)
#    never collide on the same tmux buffer (issue #14)
#  - -p -d pastes bracketed then deletes the buffer; Enter is gated on that delete
#    actually landing (polled via `show-buffer`) instead of a fixed timing guess
: "${_SEND_PROMPT_SEQ:=0}"
send_prompt() { # <target> <text...>
  local target="$1"; shift
  local text="$*"
  _SEND_PROMPT_SEQ=$((_SEND_PROMPT_SEQ + 1))
  local buf="b-${target//[^a-zA-Z0-9]/_}-$$-${RANDOM}-${_SEND_PROMPT_SEQ}"
  printf '%s' "$text" | tmux load-buffer -b "$buf" -
  tmux paste-buffer -p -d -b "$buf" -t "$target"
  # -d deletes the buffer once the paste is delivered; poll for that instead of
  # a blind sleep, capped so a stuck/renamed buffer can never hang the send.
  local i=0
  while tmux show-buffer -b "$buf" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 50 ] && break
    sleep 0.1
  done
  tmux send-keys -t "$target" Enter
}

# --- Locked worker-status writers (issue #11) ---------------------------------------
# report.sh (Stop/Notification/SubagentStop hooks) and spawn.sh both mutate
# workers/<id>.json. Unlocked, a Stop hook firing during spawn's post-inject window
# can race spawn.sh's own "working" write and land in either order (e.g. flipping a
# real `done` back to `working`). Both writers now go through the same per-id
# flock, so one write always fully lands before the next begins.

# Path to the per-worker lock file backing write_worker_status/update_worker_status.
_worker_lock_file() { echo "$WORKERS_DIR/.$1.lock"; } # <id>

# Overwrite (create or replace) a worker's status file under its lock.
# write_worker_status <id> <jq -n args...> <filter>
write_worker_status() {
  local id="$1"; shift
  local f="$WORKERS_DIR/$id.json" lock; lock="$(_worker_lock_file "$id")"
  (
    flock -x 200
    jq -n "$@" > "$f.tmp" && mv "$f.tmp" "$f"
  ) 200>"$lock"
}

# In-place jq update of a worker's status file under the same lock. Seeds the file
# with `{}` first if it doesn't exist yet, so callers can rely on a plain jq filter
# (e.g. `.status=$s`) whether or not the worker has been spawned yet.
# update_worker_status <id> <jq args...> <filter>
update_worker_status() {
  local id="$1"; shift
  local f="$WORKERS_DIR/$id.json" lock; lock="$(_worker_lock_file "$id")"
  (
    flock -x 200
    [ -f "$f" ] || printf '{}' > "$f"
    jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  ) 200>"$lock"
}

# --- Target-repo relatedness guard (issue #35) -------------------------------------
# The toolkit's own directory and the repo workers operate on are two different
# things. When the toolkit is vendored/copied into another repo (or a scaffold with
# unrelated git history and no remote), spawning must not silently worktree the
# wrong tree. "Related" means one of:
#   (a) same git top-level (toolkit dir IS the target repo),
#   (b) sibling worktrees of the same repo (shared git-common-dir),
#   (c) matching `origin` remote URLs, or
#   (d) shared history — either HEAD commit exists in the other's object database
#       (e.g. one is a clone/fork of the other).
# A toolkit dir that is not a git repo at all has nothing to contradict, so it is
# treated as related. Set ORCH_ALLOW_UNRELATED_REPO=1 to bypass entirely (a
# vendored copy with genuinely no shared history, by design).
ensure_related_repo() { # <toolkit_dir> <target_dir>  -> 0 if related/overridden
  [ "${ORCH_ALLOW_UNRELATED_REPO:-0}" = "1" ] && return 0
  local toolkit="$1" target="$2"
  local t_top g_top
  t_top="$(git -C "$toolkit" rev-parse --show-toplevel 2>/dev/null)" || return 0
  g_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$t_top" = "$g_top" ] && return 0

  local t_common g_common
  t_common="$(git -C "$t_top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || t_common=""
  g_common="$(git -C "$g_top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || g_common=""
  [ -n "$t_common" ] && [ "$t_common" = "$g_common" ] && return 0

  local t_remote g_remote
  t_remote="$(git -C "$t_top" remote get-url origin 2>/dev/null)" || t_remote=""
  g_remote="$(git -C "$g_top" remote get-url origin 2>/dev/null)" || g_remote=""
  [ -n "$t_remote" ] && [ "$t_remote" = "$g_remote" ] && return 0

  local t_head g_head
  t_head="$(git -C "$t_top" rev-parse HEAD 2>/dev/null)" || t_head=""
  g_head="$(git -C "$g_top" rev-parse HEAD 2>/dev/null)" || g_head=""
  [ -n "$g_head" ] && git -C "$t_top" cat-file -e "${g_head}^{commit}" 2>/dev/null && return 0
  [ -n "$t_head" ] && git -C "$g_top" cat-file -e "${t_head}^{commit}" 2>/dev/null && return 0

  return 1
}

# --- Worktree preflight (issue #37) -------------------------------------------------
# Before creating a worker's worktree, decide deterministically whether a
# pre-existing path at that location may be reused, instead of relying on
# `git worktree add`'s exit code (which fails identically whether the path is a
# stale leftover, a worktree of some OTHER repo, or a legitimate match). "Verifiably
# a clean worktree of the expected repo on the expected branch" means: it appears in
# `git -C <expected_repo> worktree list` at exactly this path, on exactly this
# branch, with no uncommitted changes (tracked or untracked).
worktree_matches_expected() { # <expected_repo_root> <wdir> <expected_branch> -> 0 if safe to reuse
  local expected="$1" wdir="$2" branch="$3" real_wdir
  [ -d "$wdir" ] || return 1
  real_wdir="$(cd "$wdir" 2>/dev/null && pwd)" || return 1

  local line path="" head_branch="" matched=1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ refs/heads/*) head_branch="${line#branch refs/heads/}" ;;
      "")
        if [ "$path" = "$real_wdir" ]; then
          [ "$head_branch" = "$branch" ] && matched=0
          break
        fi
        path=""; head_branch=""
        ;;
    esac
  done < <(git -C "$expected" worktree list --porcelain 2>/dev/null; printf '\n')

  [ "$matched" -eq 0 ] || return 1
  [ -z "$(git -C "$real_wdir" status --porcelain 2>/dev/null)" ] || return 1
  return 0
}

# --- Dead-worker worktree pruning (issue #37) ---------------------------------------
# A killed/crashed worker leaves its ../wt/<id> worktree and orch/<id> branch behind
# (no Stop hook fires to tear anything down). Mirrors clean.sh's worktree+branch
# teardown so a dead worker's path frees up the same way an explicit `orch clean
# <id>` would, without waiting for an operator to notice. Idempotent: a missing
# worktree/branch is a no-op, not an error.
prune_dead_worktree() { # <project_root> <id>
  local proj="$1" id="$2"
  local wdir="$proj/../wt/$id"
  if [ -d "$wdir" ]; then
    git -C "$proj" worktree remove --force "$wdir" >/dev/null 2>&1 || rm -rf "$wdir"
    log "prune_dead_worktree: removed worktree $wdir for dead worker $id"
  fi
  git -C "$proj" worktree prune >/dev/null 2>&1 || true
  if git -C "$proj" show-ref --verify --quiet "refs/heads/orch/$id"; then
    git -C "$proj" branch -D "orch/$id" >/dev/null 2>&1 || true
    log "prune_dead_worktree: deleted branch orch/$id for dead worker $id"
  fi
}

# --- Resource guard (issues #21 concurrency, #31 memory, #24 budget) ---------------

# Workers actually holding a tmux window + claude process right now: every status
# except done/spawn-failed (terminal — no process left) and queued (not launched
# yet, so it holds no slot itself — counting it would deadlock the gate, since a
# queued item could never free the very slot it's waiting on).
live_worker_count() {
  shopt -s nullglob
  local n=0 f st
  for f in "$WORKERS_DIR"/*.json; do
    st="$(jq -r '.status // ""' "$f" 2>/dev/null)"
    case "$st" in
      done|spawn-failed|queued) ;;
      *) n=$((n + 1)) ;;
    esac
  done
  echo "$n"
}

# MemAvailable from /proc/meminfo, in MB. Falls back to a large number when it
# can't be read (e.g. non-Linux dev box) so the memory gate never blocks blind.
free_mem_mb() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemAvailable:/ {print int($2/1024); found=1} END {if (!found) print 999999}' /proc/meminfo
  else
    echo 999999
  fi
}

# How many workers this orchestrator run has ever spawned (persists across
# done/failed workers, unlike live_worker_count).
spend_count() {
  if [ -f "$SPEND_FILE" ]; then
    jq -r '.spawns // 0' "$SPEND_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Coarse cumulative spend estimate in USD: spawns * budget.est_usd_per_worker.
# This is a rough per-session proxy (README: "~40K tokens/worker"), not metered usage.
est_spend_usd() {
  local est
  est="$(jq -r '.budget.est_usd_per_worker // 0' "$CONFIG" 2>/dev/null || echo 0)"
  awk -v c="$(spend_count)" -v e="$est" 'BEGIN{printf "%.2f", c*e}'
}

record_spend() {
  local n=$(( $(spend_count) + 1 ))
  jq -n --argjson s "$n" '{spawns:$s}' > "$SPEND_FILE"
}

# Unified spawn gate: concurrency cap AND free memory AND budget cap.
# Returns 0 if a spawn may proceed, 1 if it must be refused/queued — with
# $GATE_REASON set to a human-readable explanation for the refusal message.
check_spawn_gate() {
  local max_workers min_free est_worker budget_enabled budget_max est_per
  max_workers="$(jq -r '.thresholds.max_workers // 4' "$CONFIG")"
  min_free="$(jq -r '.thresholds.min_free_mb // 0' "$CONFIG")"
  est_worker="$(jq -r '.thresholds.est_worker_mb // 0' "$CONFIG")"
  budget_enabled="$(jq -r '.budget.enabled // false' "$CONFIG")"
  budget_max="$(jq -r '.budget.max_usd // 0' "$CONFIG")"
  est_per="$(jq -r '.budget.est_usd_per_worker // 0' "$CONFIG")"

  local live; live="$(live_worker_count)"
  if [ "$live" -ge "$max_workers" ]; then
    GATE_REASON="concurrency cap reached ($live/$max_workers live workers)"
    return 1
  fi

  local need=$((min_free + est_worker))
  if [ "$need" -gt 0 ]; then
    local free; free="$(free_mem_mb)"
    if [ "$free" -lt "$need" ]; then
      GATE_REASON="insufficient memory (${free}MB free, need ${need}MB = min_free_mb ${min_free} + est_worker_mb ${est_worker})"
      return 1
    fi
  fi

  if [ "$budget_enabled" = "true" ]; then
    local spent next
    spent="$(est_spend_usd)"
    next="$(awk -v s="$spent" -v e="$est_per" 'BEGIN{printf "%.2f", s+e}')"
    if awk -v n="$next" -v m="$budget_max" 'BEGIN{exit !(n > m)}'; then
      GATE_REASON="budget cap reached (est \$${spent} spent, next spawn ~\$${est_per}, cap \$${budget_max})"
      return 1
    fi
  fi

  return 0
}

# Pending-spawn queue: FIFO of JSON lines, drained by heartbeat.sh once the gate
# above allows another spawn. Collapses to one line defensively — queue_pop reads
# line-by-line, so a pretty-printed (multi-line) JSON value would corrupt the file.
queue_push() { # <json-value>
  jq -c '.' <<< "$1" >> "$QUEUE"
}

# Print and remove the oldest queued item. Returns 1 (no output) if empty.
queue_pop() {
  [ -s "$QUEUE" ] || return 1
  local first
  first="$(head -n 1 "$QUEUE")"
  tail -n +2 "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
  printf '%s\n' "$first"
}
