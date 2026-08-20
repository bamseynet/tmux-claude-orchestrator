#!/usr/bin/env bash
# _orch/lib.sh — shared helpers. Source this; do not execute directly.
# Provides: paths, log(), strip_ansi(), pane_tail(), is_busy(), is_ready(),
#           wait_ready(), send_prompt(), spawn-injection guards
#           pane_has_welcome(), pane_active(), inject_confirmed(), confirm_inject(),
#           pane_has_draft() (master draft guard, issue #38),
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

# --- Test-isolation leak guard (issue #68) ------------------------------------------
# A worker's own hermetic bats tests are meant to redirect ORCH_ROOT to a throwaway
# tmp dir before touching any of this. If a test forgets to (or inherits ORCH_ROOT
# from the worker's own launch env, which points at the PARENT orchestrator's real
# toolkit), state writes land in the live orchestrator's _orch/state — observed as a
# stray workers/w1.json leaking into the parent (issue #68). When running under bats
# ($BATS_TEST_FILENAME set) and STATE_DIR does not fall under one of bats' own tmp
# roots, treat ORCH_ROOT as unisolated and redirect state to a private scratch dir
# instead of writing into whatever ORCH_ROOT resolved to. Production runs (no BATS_*
# env) are completely unaffected.
if [ -n "${BATS_TEST_FILENAME:-}" ]; then
  _orch_isolated=0
  for _orch_bats_root in "${BATS_TEST_TMPDIR:-}" "${BATS_SUITE_TMPDIR:-}" "${BATS_RUN_TMPDIR:-}" "${BATS_TMPDIR:-}"; do
    [ -n "$_orch_bats_root" ] || continue
    case "$STATE_DIR" in
      "$_orch_bats_root"*) _orch_isolated=1; break ;;
    esac
  done
  if [ "$_orch_isolated" -ne 1 ]; then
    _orch_leak_guard_dir="$(mktemp -d "${TMPDIR:-/tmp}/orch-bats-leak-guard.XXXXXX")"
    printf '%s orch-test-isolation-guard: %s did not isolate ORCH_ROOT (resolved state to %s, not a bats tmp dir) -- redirecting state to %s\n' \
      "$(date -u +%FT%TZ)" "${BATS_TEST_FILENAME:-unknown}" "$STATE_DIR" "$_orch_leak_guard_dir/state" >&2
    STATE_DIR="$_orch_leak_guard_dir/state"
    WORKERS_DIR="$STATE_DIR/workers"
    INBOX="$STATE_DIR/inbox.jsonl"
    LOG="$STATE_DIR/orch.log"
    QUEUE="$STATE_DIR/queue.jsonl"
    SPEND_FILE="$STATE_DIR/spend.json"
  fi
  unset _orch_isolated _orch_bats_root _orch_leak_guard_dir
fi

mkdir -p "$WORKERS_DIR"

# --- Per-toolkit session namespacing (issue #81) ------------------------------------
# The tmux session name used to be the bare literal "orch", so two installs of this
# toolkit in different directories collided on the same session: bootstrap.sh from
# either one reported "session 'orch' already exists; reusing" and silently adopted
# the OTHER install's session, and `orch down` from one install signalled the other
# install's heartbeat/watchdog loops. Default the session name to a short hash of
# the resolved toolkit root instead, so two installs never share a name by accident.
# `SESSION_NAME` (already the established override var — see `orch help`) still wins
# when set explicitly, e.g. to pin a memorable name or to intentionally point two
# installs at the same session.
_orch_session_hash() { # <string> -> 8 hex chars, stable across shells/platforms
  local s="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha1sum | cut -c1-8
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum | cut -c1-8
  elif command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$s" | md5sum | cut -c1-8
  else
    printf '%s' "$s" | cksum | cut -d' ' -f1
  fi
}
: "${SESSION_NAME:=orch-$(_orch_session_hash "$ORCH_ROOT")}"      # tmux session name
: "${ORCH_WINDOW:=orchestrator}"  # master window name

# --- Per-toolkit git-layer namespacing (issue #86) -----------------------------------
# Two orch installs targeting the SAME target repo used to both want the worktree
# $proj/../wt/<id> and the branch orch/<id> — the reuse guard below would then treat
# the second install's spawn as "already a clean worktree ... reusing" and silently
# hand it the first install's worktree and branch. Key the worktree path and branch
# name on the same per-ORCH_ROOT hash used for SESSION_NAME above, so two installs
# never collide on the git layer by accident, same as #81 did for the tmux session.
# Normalize a trailing slash before hashing (ORCH_ROOT=/foo/bar/ vs /foo/bar must
# not silently fork the git namespace) and allow an explicit ORCH_HASH override —
# a manual recovery escape hatch if ORCH_ROOT's resolved form ever changes out from
# under an install (moved, re-symlinked) and stranded worktrees/branches under the
# old hash; same override precedent as SESSION_NAME above.
: "${ORCH_HASH:=$(_orch_session_hash "${ORCH_ROOT%/}")}"

worker_wdir() { # <project_root> <id> -> this install's worktree path for <id>
  printf '%s/../wt/%s/%s' "$1" "$ORCH_HASH" "$2"
}

worker_branch() { # <id> -> this install's branch name for <id>
  printf 'orch/%s/%s' "$ORCH_HASH" "$1"
}

# Pre-#86 layout, kept only so clean.sh/prune can sweep up leftovers from before
# this install upgraded (see the "Back-compat" note in lib.sh's header comment).
legacy_worker_wdir() { printf '%s/../wt/%s' "$1" "$2"; } # <project_root> <id>
legacy_worker_branch() { printf 'orch/%s' "$1"; }        # <id>

# --- Worktree ownership marker (issue #86) --------------------------------------------
# Namespacing above makes an accidental collision very unlikely (it takes two
# different ORCH_ROOTs to hash to the same 8 hex chars), but "very unlikely" is not
# "impossible" — and an operator could still force one, e.g. by hand-editing state.
# Belt-and-suspenders: stamp the owning ORCH_ROOT into the worktree's private admin
# dir (`.git/worktrees/<name>/orch-owner` in the TARGET repo) at creation time —
# deliberately NOT inside the worktree's own working tree, so it never shows up in
# `git status` and can't break the "is this worktree clean" reuse check below. A
# foreign install can then tell it does not own a path it's about to touch and
# refuse loudly instead of silently adopting it.
_worktree_owner_file() { # <wdir> -> admin-dir path, empty/nonzero if not a LINKED worktree
  local gd
  gd="$(git -C "$1" rev-parse --git-dir 2>/dev/null)" || return 1
  case "$gd" in /*) ;; *) gd="$1/$gd" ;; esac
  # A linked worktree's private git-dir always lives under <main-repo>/.git/worktrees/
  # <name>/. Anything else (the main working tree itself, or some OTHER path that
  # simply happens to sit inside a git repo, e.g. a stray dir under an enclosing
  # dotfiles/monorepo checkout) is not a worktree admin dir -- refuse it rather than
  # writing/reading an owner file that would actually belong to the enclosing repo.
  case "$gd" in */worktrees/*) ;; *) return 1 ;; esac
  printf '%s/orch-owner' "$gd"
}

stamp_worktree_owner() { # <wdir> -- record this install as the owner
  local f
  f="$(_worktree_owner_file "$1")" || return 1
  printf '%s\n' "$ORCH_ROOT" > "$f" || { log "stamp_worktree_owner: failed to write $f"; return 1; }
}

worktree_owner() { # <wdir> -> prints the owning ORCH_ROOT, empty if unmarked
  local f
  f="$(_worktree_owner_file "$1")" || return 0
  [ -f "$f" ] && cat "$f"
  return 0
}

worktree_owned_by_other() { # <wdir> -> 0 if marked with a DIFFERENT ORCH_ROOT
  local owner
  owner="$(worktree_owner "$1")"
  [ -n "$owner" ] && [ "$owner" != "$ORCH_ROOT" ]
}

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
# Placeholder/hint text that can legitimately follow the glyph on an otherwise-empty
# input row (issue #52) — broaden this list via config as the TUI's copy changes,
# rather than hardcoding new patterns into pane_has_draft() itself.
TUI_DRAFT_PLACEHOLDER_REGEX="$(_tui_pattern draft_placeholder_regex '^(Try "|for shortcuts|\? for shortcuts|Context (left|low)|tokens? (saved|left|used))')"

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

# --- Master draft guard (issue #38, hardened by #52) --------------------------------
# An idle input box with an unsent operator draft looks identical to an empty idle
# input box to is_ready() — both are "not busy, prompt glyph visible". Heartbeat
# injection must not paste over (and Enter away) a draft the operator is mid-typing.
#
# Issue #52: the original implementation grepped ALL of the last 15 pane lines for
# the input-glyph regex and took the LAST matching line as "the input line". Any
# completed tool-output table/box-border row containing "│ >" (or the bare "❯"
# glyph appearing in unrelated output) could therefore be mistaken for the live
# input row, and any hint text on the true input row other than the two
# hardcoded placeholders was treated as a draft — so this failed CLOSED and the
# heartbeat requeued every worker event forever. It must fail OPEN instead: only
# the true prompt row (the pane's last non-blank line, which is where a live
# cursor always renders) is inspected, and only a high-confidence non-placeholder
# match on THAT line counts as a draft. Any other shape — no glyph on the last
# line, a placeholder/hint, or an empty pane — is treated as "no draft", the safe
# default, and lets the placeholder allow-list broaden via config instead of code
# changes (issue #52 config knob).
pane_has_draft() { # <target>  -> 0 ONLY if the true (last) input line holds unsent operator text
  local line rest
  line="$(pane_tail "$1" 15 | grep -v '^[[:space:]]*$' | tail -n 1)"
  [ -n "$line" ] || return 1
  [[ "$line" =~ ^[[:space:]]*($TUI_INPUT_GLYPH_REGEX)[[:space:]]?(.*)$ ]] || return 1
  rest="${BASH_REMATCH[2]}"
  [[ "$rest" =~ ^[[:space:]]*$ ]] && return 1
  [[ "$rest" =~ $TUI_DRAFT_PLACEHOLDER_REGEX ]] && return 1
  return 0
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

# --- Dependency check (issue #20) ----------------------------------------------------
# Previously only bootstrap.sh verified required binaries were present, so a missing
# jq/tmux/perl (etc.) surfaced as a cryptic failure mid-command instead of a clear
# message up front. Centralized here so every entrypoint can share the same check
# instead of duplicating the loop.
check_deps() { # <dep>...  -> 0 if all present; prints one line per missing dep otherwise
  local dep missing=0
  for dep in "$@"; do
    command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; missing=1; }
  done
  return "$missing"
}

# --- Portable exclusive-lock shim (issue #76) ----------------------------------------
# flock(1) is util-linux; it does not exist on macOS/BSD. Everything below routes
# through with_lock() instead of calling `flock` directly, so the three callers
# (write_worker_status, update_worker_status, review_log_append) get real mutual
# exclusion on Linux (flock, unchanged behaviour) and on macOS (an atomic
# mkdir-based mutex — mkdir is atomic on every POSIX filesystem and needs no extra
# binary). A holder that dies while holding the mkdir lock cannot wedge it forever:
# stale locks are reclaimed by checking whether the recorded PID is still alive,
# and independently by age, and a bounded wait means a caller that truly cannot
# acquire the lock gets a loud, non-zero-exit failure back — never a silent
# unlocked fallthrough.
: "${ORCH_LOCK_TIMEOUT:=30}"     # seconds to wait for the lock before giving up
: "${ORCH_LOCK_STALE_AGE:=60}"   # seconds before an abandoned mkdir lock is reclaimed

# mtime of a path in epoch seconds, GNU or BSD stat. Prints nothing and returns
# non-zero if the path is gone or neither stat dialect works -- callers must not
# treat a bare fallthrough as a valid (zero) mtime. Note GNU stat's `-f` means
# "filesystem status", not "format string" (that's BSD), so a naive
# `stat -c ... || stat -f %m ...` would, on GNU stat, print unrelated filesystem
# info to stdout on the fallback branch even though it exits non-zero -- capture
# each attempt and gate on its own exit status instead of letting `||` alone
# decide what reaches the caller.
_lock_mtime() { # <path>
  local out
  out="$(stat -c %Y "$1" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
  out="$(stat -f %m "$1" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
  return 1
}

# Acquire an exclusive lock at <lock_path>, for the lifetime of the CALLING
# subshell/process — release is automatic (flock: fd closes; mkdir fallback: an
# EXIT/INT/TERM trap removes the lock dir), so this must be invoked inside a
# `( ... )` subshell scoped to just the critical section, e.g.:
#   ( with_lock "$lock" || exit 1; <critical section> )
# Returns 1 (with a message on stderr) if the lock cannot be acquired within
# ORCH_LOCK_TIMEOUT seconds — callers must check this, not assume success.
with_lock() { # <lock_path>
  local lock="$1"

  if command -v flock >/dev/null 2>&1; then
    exec 200>"$lock" || { echo "with_lock: cannot open lock file $lock" >&2; return 1; }
    if ! flock -x -w "$ORCH_LOCK_TIMEOUT" 200; then
      echo "with_lock: timed out waiting for lock $lock (flock)" >&2
      return 1
    fi
    return 0
  fi

  # mkdir-based fallback (macOS/BSD: no flock(1) binary).
  local lockdir="$lock.d" start_ts holder_pid mtime
  start_ts=$(date +%s)
  while ! mkdir "$lockdir" 2>/dev/null; do
    if [ -f "$lockdir/pid" ]; then
      holder_pid="$(cat "$lockdir/pid" 2>/dev/null)"
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null
        continue
      fi
    fi
    # A concurrent holder may release (rm -rf) the lock dir between the failed
    # mkdir above and this stat, so mtime can legitimately come back empty --
    # that just means it's gone, not stale; skip the age check for this pass
    # rather than doing arithmetic on an empty value.
    mtime="$(_lock_mtime "$lockdir")"
    if [ -n "$mtime" ] && [ $(( $(date +%s) - mtime )) -ge "$ORCH_LOCK_STALE_AGE" ]; then
      rm -rf "$lockdir" 2>/dev/null
      continue
    fi
    if [ $(( $(date +%s) - start_ts )) -ge "$ORCH_LOCK_TIMEOUT" ]; then
      echo "with_lock: timed out waiting for lock $lock (mkdir)" >&2
      return 1
    fi
    sleep 0.1
  done
  echo $$ > "$lockdir/pid" 2>/dev/null
  # $lockdir is local to this function and gone by the time the trap actually
  # fires, so bake its value into the trap command now rather than referencing
  # the variable (which would expand to empty and rm nothing).
  # shellcheck disable=SC2064
  trap "rm -rf $(printf '%q' "$lockdir")" EXIT INT TERM
  return 0
}

# --- Locked worker-status writers (issue #11) ---------------------------------------
# report.sh (Stop/Notification/SubagentStop hooks) and spawn.sh both mutate
# workers/<id>.json. Unlocked, a Stop hook firing during spawn's post-inject window
# can race spawn.sh's own "working" write and land in either order (e.g. flipping a
# real `done` back to `working`). Both writers now go through the same per-id
# with_lock, so one write always fully lands before the next begins.

# Path to the per-worker lock file backing write_worker_status/update_worker_status.
_worker_lock_file() { echo "$WORKERS_DIR/.$1.lock"; } # <id>

# Overwrite (create or replace) a worker's status file under its lock.
# write_worker_status <id> <jq -n args...> <filter>
write_worker_status() {
  local id="$1"; shift
  local f="$WORKERS_DIR/$id.json" lock; lock="$(_worker_lock_file "$id")"
  (
    with_lock "$lock" || exit 1
    jq -n "$@" > "$f.tmp" && mv "$f.tmp" "$f"
  )
}

# In-place jq update of a worker's status file under the same lock. Seeds the file
# with `{}` first if it doesn't exist yet, so callers can rely on a plain jq filter
# (e.g. `.status=$s`) whether or not the worker has been spawned yet.
# update_worker_status <id> <jq args...> <filter>
update_worker_status() {
  local id="$1"; shift
  local f="$WORKERS_DIR/$id.json" lock; lock="$(_worker_lock_file "$id")"
  (
    with_lock "$lock" || exit 1
    [ -f "$f" ] || printf '{}' > "$f"
    jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  )
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
  local wdir branch owned_by_other=0
  wdir="$(worker_wdir "$proj" "$id")"
  branch="$(worker_branch "$id")"
  if [ -d "$wdir" ]; then
    # Never remove a path this install did not stamp itself — namespacing means
    # this should be unreachable in practice, but a dead-worker sweep is automatic
    # (no operator in the loop), so it gets the same foreign-ownership guard as
    # spawn.sh rather than trusting the path is ours just because it looks right.
    # The guard covers the branch delete below too (not just the worktree itself):
    # `worktree prune` right after can un-register a foreign worktree, which would
    # otherwise let git's own "branch checked out elsewhere" refusal be bypassed.
    if worktree_owned_by_other "$wdir"; then
      owned_by_other=1
      log "prune_dead_worktree: refusing to touch $wdir for $id — owned by a different orch install ($(worktree_owner "$wdir"))"
    else
      git -C "$proj" worktree remove --force "$wdir" >/dev/null 2>&1 || rm -rf "$wdir"
      log "prune_dead_worktree: removed worktree $wdir for dead worker $id"
    fi
  fi
  git -C "$proj" worktree prune >/dev/null 2>&1 || true
  if [ "$owned_by_other" -eq 0 ] && git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$proj" branch -D "$branch" >/dev/null 2>&1 || true
    log "prune_dead_worktree: deleted branch $branch for dead worker $id"
  fi
}

# --- Human ownership flag (issue #70) -----------------------------------------------
# `orch attach <id>` hands a worker over to a human for direct control; `orch detach
# <id>` hands it back to the orchestrator. The flag is a plain marker file (not a
# `workers/<id>.json` field) so it can be set/cleared without contending with
# write_worker_status's per-id flock, and so a worker can be flagged before its
# status file even exists. It is deliberately independent of tmux attachment state:
# a human may attach/detach the *terminal* (Ctrl-b d) repeatedly while still "owning"
# the worker — only `orch detach` clears ownership.
_manual_marker() { echo "$STATE_DIR/.manual-$1"; } # <id> -> marker path

is_human_managed() { [ -f "$(_manual_marker "$1")" ]; } # <id> -> 0 if human-managed

mark_human_managed() { # <id>
  mkdir -p "$STATE_DIR"
  : > "$(_manual_marker "$1")"
  log "worker '$1' marked human-managed (orch attach)"
}

clear_human_managed() { # <id>
  rm -f "$(_manual_marker "$1")"
  log "worker '$1' handed back to the orchestrator (orch detach)"
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
