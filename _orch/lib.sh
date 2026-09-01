#!/usr/bin/env bash
# _orch/lib.sh — shared helpers. Source this; do not execute directly.
# Provides: paths, log(), session_exists(), strip_ansi(), pane_tail(), is_busy(), is_ready(),
#           wait_ready(), send_prompt(), spawn-injection guards
#           pane_has_welcome(), pane_active(), pane_has_pending_paste(), inject_confirmed(), confirm_inject(),
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
# tmux treats ':' and '.' as target separators (session:window.pane), so a name
# containing either would silently target the wrong thing everywhere SESSION_NAME
# is interpolated into a tmux target. Keep the allowed charset conservative.
# Applied below to whatever SESSION_NAME actually resolves to (issue #92) — not
# just a fresh `--name` value — so a bad SESSION_NAME env or a hand-edited
# persisted-name file fails loudly here instead of silently mistargeting later.
valid_session_name() { # <name> -> 0 if safe to use as a tmux session name
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# --- Nameable, persistent sessions (issue #92) --------------------------------------
# `--name` at `orch up` persists a memorable session name to $STATE_DIR/session-name
# so every later `orch` invocation (a different shell, a cron job, after a reboot)
# resolves to the SAME session without re-exporting SESSION_NAME every time.
# Precedence: SESSION_NAME env (still wins here, unchanged/back-compat) > persisted
# name > the #81 hash default below. `orch up --name` itself (bootstrap.sh) additionally
# overrides SESSION_NAME before this file is sourced from a fresh shell, so it
# effectively sits above the env tier for THAT invocation.
_orch_persisted_session_name() { # -> prints the persisted name; returns 1 (no output) if unset/empty
  local f="$STATE_DIR/session-name" v
  [ -f "$f" ] || return 1
  v="$(cat "$f" 2>/dev/null)"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}
if [ -z "${SESSION_NAME:-}" ]; then
  # `if var=$(cmd)` (not a bare `var=$(cmd)` statement) keeps this exempt from
  # `set -e`: the assignment's exit status is only inspected, never left to
  # abort the sourcing script on a "no persisted name yet" 1.
  if _orch_persisted="$(_orch_persisted_session_name)"; then
    SESSION_NAME="$_orch_persisted"
  else
    SESSION_NAME="orch-$(_orch_session_hash "$ORCH_ROOT")"
  fi
  unset _orch_persisted
fi
# Validate whatever SESSION_NAME resolved to -- env override, persisted file, or
# (already-safe) hash default -- not just a fresh `--name` value. SESSION_NAME='a:b'
# was previously accepted unvalidated and would silently target the wrong tmux
# pane everywhere it's interpolated. This must NOT be a hard `exit` here, though
# (issue #92 rv92 finding): lib.sh is sourced unconditionally by every entrypoint,
# including ones that need no valid session name at all -- `orch help`, `orch
# down` (stop.sh only prints SESSION_NAME in a cosmetic message; killing the
# loops needs no tmux target), `orch status`/`logs`/`events`. A top-level exit
# here would take those out too, with no way to recover short of hand-editing
# state on disk. Record the problem instead; entrypoints that actually
# interpolate SESSION_NAME into a tmux target call require_valid_session_name
# themselves, right before they use it -- see ask.sh/bootstrap.sh/clean.sh/
# heartbeat.sh/send.sh/send-remote-control.sh/spawn.sh/watchdog.sh and orch's
# own tail/attach cases.
SESSION_NAME_ERROR=""
if ! valid_session_name "$SESSION_NAME"; then
  SESSION_NAME_ERROR="orch: invalid session name [$SESSION_NAME] (from \$SESSION_NAME or a persisted name at $STATE_DIR/session-name) -- session names may contain only letters, digits, _ and - (tmux treats : and . as target separators, so either would silently target the wrong pane). Fix or unset \$SESSION_NAME, remove the persisted-name file, or run: orch up --name <valid-name>"
fi
require_valid_session_name() { # call before interpolating $SESSION_NAME into a tmux target
  if [ -n "$SESSION_NAME_ERROR" ]; then
    echo "$SESSION_NAME_ERROR" >&2
    exit 1
  fi
}

# --- Exact session-existence check (issue #96) ----------------------------------
# tmux target resolution allows an UNAMBIGUOUS PREFIX to match a session name
# (e.g. `-t bill` hits a live session named "billing" -- confirmed against tmux
# 3.4). A plain `tmux has-session -t <name>` is therefore not safe to use for
# "does a session with exactly this name exist": it can silently report success
# against a completely different, longer-named session, which is exactly the
# --name hijack trap issue #92 warns about. List sessions and match the name
# literally instead. (Promoted from bootstrap.sh, where issue #92 originally
# added it.)
#
# session_exists() itself only answers the existence question -- it does not
# stop a caller from going on to pass `-t "$S"` straight to a MUTATING tmux
# command, which would still get tmux's own prefix resolution. That write-path
# hazard is what require_session_exists(), just below, guards against (#107);
# read paths (tail/attach/ask) and decision paths (update/bootstrap) call
# session_exists() directly (#104).
session_exists() { # <name> -> 0 if a session with that EXACT name exists
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qxF -- "$1"
}

# require_session_exists() (issue #107): the shared "fail before any tmux write"
# guard for the hard-error call sites (send.sh, spawn.sh, ask.sh) -- a bare
# `-t "$S"` target matches by UNAMBIGUOUS PREFIX, so a caller skipping this check
# could silently type/spawn into a DIFFERENT, longer-named live session instead
# of failing. One shared helper next to session_exists() itself, so a future
# write-path call site can't reintroduce the hazard by forgetting to duplicate it.
# clean.sh/watchdog.sh intentionally do NOT use this: their idempotent-teardown
# semantics need a no-op-if-missing check, not an error exit.
require_session_exists() { # <name> -> exits 1 with a standard message if it doesn't
  if ! session_exists "$1"; then
    say "no such tmux session: $1" >&2
    exit 1
  fi
}
export SESSION_NAME SESSION_NAME_ERROR    # tmux session name
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

# --- Timestamped terminal output (issue #90) -----------------------------------
# orch.log (log(), above) is already timestamped on every line; the interactive
# surface (orch status/spawn/clean, queue/refusal/error messages) was not, making
# it impossible to tell how old a scrollback line is in an unattended session, or
# to line a terminal line up against the matching orch.log entry for the same
# event. say() is the one helper every human-facing print goes through. It must
# NEVER be used for machine-readable payloads (orch status --json, collect's JSON,
# a worker's pane-tail reply) — those stay byte-identical, unprefixed.
#
# Precedence (highest first), mirroring the env-beats-config convention used for
# target-repo resolution above: $ORCH_TIMESTAMPS > output.timestamps in
# config.json > default on. Deliberately WIDER than the rest of this repo's env
# booleans (ORCH_ALLOW_SKIP_PERMISSIONS/ORCH_ALLOW_UNRELATED_REPO check a
# strict "1") — this one is a display toggle a human is expected to type by
# hand, so 0/false/off/no and 1/true/on/yes are all accepted. An unrecognized
# value (e.g. "FALSE", "n") is deliberately NOT an error: it falls through to
# config.json's value, same as an unset var — never silently coerced to a
# guess in either direction.
#
# The config.json half of that (a jq invocation) is resolved ONCE here, at
# source time — same pattern as SESSION_NAME/ORCH_HASH above — into
# _ORCH_CFG_TIMESTAMPS_DEFAULT/_ORCH_CFG_TIMESTAMP_FORMAT_DEFAULT, not
# re-read on every call. say() is meant to sit behind every human-facing
# print in the toolkit, so a per-line jq fork would compound as adoption
# grows; jq is also the slowest thing in this toolkit's startup path. The env
# check stays live (a bare case statement, no subprocess) so
# ORCH_TIMESTAMPS/ORCH_TIMESTAMP_FORMAT still override even when set after
# lib.sh is sourced.
#
# This is the SAME once-per-process model already used elsewhere, not a new
# behavior: heartbeat.sh reads intervals.*/heartbeat.* from $CONFIG once at
# heartbeat_main() startup, before its `while` loop, not on every tick.
# There IS a real asymmetry worth knowing, though: `orch` CLI commands are
# short-lived (a fresh process, hence a fresh config read, on every
# invocation), while heartbeat.sh/watchdog.sh are long-lived background
# loops — once one of those is running, an operator's mid-session
# config.json edit (including output.timestamps/output.timestamp_format)
# will not reach it until it's restarted. That was already true for
# intervals/thresholds before this change; say() now follows the same rule.
# One jq call for both keys, not two — the `|| printf 'on\tiso\n'` fallback
# matters beyond cost: a bare `x="$(jq ...)"` is a single simple command, so
# under `set -e` (every caller sources this) jq failing outright — e.g.
# CONFIG doesn't exist yet, a fresh install/partial test scaffold — would
# abort the WHOLE sourcing script, not just fall back to the defaults.
# Folding the fallback inside the substitution keeps the assignment itself
# always successful.
_orch_output_cfg="$(jq -r '[(if .output.timestamps == false then "off" else "on" end), (.output.timestamp_format // "iso")] | @tsv' "$CONFIG" 2>/dev/null || printf 'on\tiso\n')"
# A zero-byte config.json (truncated file, `> config.json` typo, etc.) makes
# jq exit 0 with EMPTY output rather than erroring, so the `||` fallback
# above never fires and _orch_output_cfg is "" instead of "on<TAB>iso". The
# split below would then leave both defaults as empty strings — behavior
# still happens to come out right today (orch_timestamps_enabled checks
# != "off" and the format check is = "short", so "" reads as "on"/default),
# but that's an accident of those specific comparisons, not the documented
# on/iso invariant. Pin it explicitly instead of relying on it.
[ -n "$_orch_output_cfg" ] || _orch_output_cfg=$'on\tiso'
_ORCH_CFG_TIMESTAMPS_DEFAULT="${_orch_output_cfg%%$'\t'*}"
_ORCH_CFG_TIMESTAMP_FORMAT_DEFAULT="${_orch_output_cfg#*$'\t'}"
unset _orch_output_cfg

orch_timestamps_enabled() {
  case "${ORCH_TIMESTAMPS:-}" in
    0 | false | off | no) return 1 ;;
    1 | true | on | yes) return 0 ;;
  esac
  [ "$_ORCH_CFG_TIMESTAMPS_DEFAULT" != "off" ]
}

# Format precedence: $ORCH_TIMESTAMP_FORMAT > output.timestamp_format in
# config.json > default "iso". "iso" matches orch.log's %FT%TZ UTC stamp exactly
# (best for correlating a terminal line against the log); "short" is a local
# HH:MM:SS clock (best for reading a live-attached session at a glance). This
# is the ONLY place that precedence is decided — say() below calls it rather
# than re-deriving the same rule, so the two can never drift apart.
orch_timestamp_format() {
  local fmt="${ORCH_TIMESTAMP_FORMAT:-}"
  [ -n "$fmt" ] || fmt="$_ORCH_CFG_TIMESTAMP_FORMAT_DEFAULT"
  printf '%s' "$fmt"
}

# say <text...> — a human-facing line, timestamp-prefixed unless disabled.
# Always writes to stdout; redirect the call itself for stderr (e.g. `say "..." >&2`),
# same as the bare echo/printf calls it replaces. Two cheap subshell forks per
# call (orch_timestamp_format(), `date`) — no jq, no external processes beyond
# `date` itself; orch_timestamps_enabled() is pure shell, no fork at all.
say() {
  if orch_timestamps_enabled; then
    if [ "$(orch_timestamp_format)" = "short" ]; then
      printf '%s %s\n' "$(date +%T)" "$*"
    else
      printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"
    fi
  else
    printf '%s\n' "$*"
  fi
}

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

# --- Claude Code launch env (issues #140, #144) ---------------------------------------
# Env prefix prepended to every `claude` launch line this toolkit types into a
# tmux pane (worker spawn and master bootstrap): suppresses auto-generated text
# this toolkit never wants -- the prompt-suggestion ghost row (#140) and the
# session recap row (#144). Both vars are the empirically verified mechanism;
# CLI flag routes for either were disproved and must not come back (flag names
# are written without their dashes here so the acceptance tests can forbid the
# real spelling in this file too).
# Centralized here -- rather than duplicated at each of the two launch sites --
# so the two can never drift, exactly like the TUI patterns below. Keep the
# TRAILING SPACE: call sites interpolate it directly ahead of `claude`.
# #144: CLAUDE_CODE_ENABLE_AWAY_SUMMARY is PREPENDED (not appended) ahead of
# PROMPT_SUGGESTION so #140's tests -- which assert the exact adjacency
# "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude ..." -- stay green.
ORCH_GHOST_ENV="CLAUDE_CODE_ENABLE_AWAY_SUMMARY=false CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false "

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
# The input box's own side borders. Claude Code renders the prompt row framed
# ("│ ❯ text                 │") on some builds and bare ("❯ text") on others;
# pane_has_draft() anchors the glyph at line start (that anchoring is the #52
# safety valve against tool-output table rows), so without discounting the
# opening border the framed shape matches nothing at all — the guard goes
# inert, and any stale bare-"❯" scrollback echo higher in the tail becomes the
# "last glyph row" instead. The glyph must follow the border with nothing but
# spaces between it, which is what keeps "│ w1 │ > 5 │" style table rows failing
# open. An earlier bound of "border + at most TWO spaces" (rv142 pass 1) was
# tighter still, but overrunning it fails in the dangerous direction: a real
# draft in a wider-padded box ("│   ❯ draft   │") then matched nothing at all,
# so the guard went inert and the heartbeat clobbered the draft -- and the
# tightness bought no #52 safety, since an indented bare "❯" already matches
# via the leading [[:space:]]* with or without the border group.
TUI_BOX_BORDER_REGEX="$(_tui_pattern box_border_regex '│[[:space:]]*')"
TUI_BOX_BORDER_CLOSE_REGEX="$(_tui_pattern box_border_close_regex '│')"
# How many pane rows pane_has_draft() scans back for the input row. Must exceed
# the tallest draft an operator plausibly leaves unsent plus the footer below
# the box, because the input glyph sits on the draft's first row only.
TUI_DRAFT_SCAN_LINES_DEFAULT=60
TUI_DRAFT_SCAN_LINES="$(_tui_pattern draft_scan_lines "$TUI_DRAFT_SCAN_LINES_DEFAULT")"
# A non-numeric override would make `tail -n` fail, and "0" (which IS numeric)
# makes `tail -n 0` emit nothing at all -- both leave an empty capture and a
# silent "no draft", the direction that clobbers operator text. Any value that
# cannot yield at least one scanned row falls back to the default.
case "$TUI_DRAFT_SCAN_LINES" in
  ''|*[!0-9]*) TUI_DRAFT_SCAN_LINES="$TUI_DRAFT_SCAN_LINES_DEFAULT" ;;
  *) [ "$TUI_DRAFT_SCAN_LINES" -ge 1 ] || TUI_DRAFT_SCAN_LINES="$TUI_DRAFT_SCAN_LINES_DEFAULT" ;;
esac
# Placeholder/hint text that can legitimately follow the glyph on an otherwise-empty
# input row (issue #52) — broaden this list via config as the TUI's copy changes,
# rather than hardcoding new patterns into pane_has_draft() itself.
TUI_DRAFT_PLACEHOLDER_REGEX="$(_tui_pattern draft_placeholder_regex '^(Try "|for shortcuts|\? for shortcuts|Context (left|low)|tokens? (saved|left|used))')"
# The collapsed "[Pasted text ...]" chip the TUI shows for an unsent paste
# still sitting in the input box (issue #128).
TUI_PASTE_CHIP_REGEX="$(_tui_pattern paste_chip_regex '\[Pasted text( #[0-9]+)?( \+[0-9]+ lines?)?\]')"

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

# A pending, un-submitted "[Pasted text]" chip sitting on the input row --
# proof the paste landed but was never dispatched (issue #128). Like
# pane_has_draft(), this locates the input row as the LAST line carrying the
# input glyph rather than the pane's last non-blank line: on a real Claude
# Code worker pane the model/mode footer ("Sonnet 5 <id>", "auto mode on")
# renders BELOW the input box once the TUI has drawn once, so the input row
# holding the chip is never the last non-blank line. (pane_has_draft() used
# the last-non-blank-line rule until issue #141, which is exactly the bug #141
# fixed there.) It still differs from pane_has_draft() in two ways: the match
# is unanchored (a chip row is high-confidence evidence wherever the glyph
# sits on it), and inject_confirmed needs the opposite bias -- fail toward
# "not confirmed", so an input row showing an unsent chip disqualifies the
# injection regardless of what else is rendered below it.
#
# Only the LAST input-glyph row in the tail is inspected, not every matching
# row: an unsent chip can only ever sit on the live input row, which is always
# the lowest such row on screen. Scanning every row would also match the TUI's
# echo of a chip for a paste that WAS submitted (and a resumed session's
# replayed transcript), keeping inject_confirmed at "not confirmed" for a
# worker that is happily running the task -- costing it a duplicate re-inject
# and a bogus spawn-failed.
pane_has_pending_paste() { # <target>  -> 0 if an un-submitted paste chip is visible
  local line input_row=""
  while IFS= read -r line; do
    [[ "$line" =~ $TUI_INPUT_GLYPH_REGEX ]] && input_row="$line"
  done <<< "$(pane_tail "$1" 25)"
  [ -n "$input_row" ] || return 1
  [[ "$input_row" =~ $TUI_PASTE_CHIP_REGEX ]]
}

# An injected prompt appears to have landed. Requires positive evidence rather than
# defaulting to "landed" (issue #12): either the pane carries a genuine mid-turn
# marker, or — with the startup banner already scrolled away and no unsent paste
# chip on the input row — the pane shows spinner activity or is back at a ready
# prompt (i.e. it landed and finished fast). Anything else — including "banner
# already gone but no activity and no ready prompt either", and any shape of
# never-dispatched injection under a still-visible banner (issue #128) — is
# treated as NOT confirmed, so spawn.sh's retry/failure path can kick in instead
# of silently trusting it.
inject_confirmed() { # <target>  -> 0 if the injection looks accepted
  # A genuine mid-turn marker ("esc to interrupt") is unambiguous proof a turn
  # is running, so it wins outright: the chip guard below must never talk a
  # demonstrably-working worker into a duplicate re-inject and a spawn-failed.
  # The startup banner carries no such marker, so #128's shape still falls
  # through to the guard.
  is_busy "$1" && return 0
  # Checked BEFORE pane_active: an unsent chip disqualifies the injection no
  # matter what else is on screen. The real startup banner is "✻ Welcome to
  # Claude Code!", and that "✻" matches TUI_ACTIVE_GLYPH_REGEX -- so with
  # pane_active first, the exact shape #128 reports (banner still up, chip
  # unsent, task never dispatched) confirms as "landed" on the banner's own
  # glyph and neither this guard nor pane_has_welcome is ever reached.
  pane_has_pending_paste "$1" && return 1
  # Checked BEFORE pane_active for the same reason (rv129): the banner's own
  # "✻" is an ACTIVE-glyph match, so with pane_active first this line was
  # unreachable in practice on a real worker pane and ANY shape of
  # never-dispatched injection under a still-visible banner confirmed as
  # "landed" -- not just the paste-chip shape #128 reported. A single-line task
  # short enough that Claude Code renders it literally instead of collapsing it
  # into a chip, or a paste lost outright leaving an empty input box, both look
  # exactly like that. The banner is unambiguous: it only survives while no
  # prompt has been accepted, so it disqualifies the injection outright. A
  # worker genuinely mid-turn is already confirmed by is_busy() above, before
  # either check.
  pane_has_welcome "$1" && return 1
  pane_active "$1" && return 0
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

# --- Master draft guard (issue #38, hardened by #52 and #101) -----------------------
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
# the true prompt row is inspected, and only a high-confidence non-placeholder
# match on THAT line counts as a draft. Any other shape — no glyph on the true
# input row, a placeholder/hint, or an empty pane — is treated as "no draft", the
# safe default, and lets the placeholder allow-list broaden via config instead of
# code changes (issue #52 config knob).
#
# Issue #141: "the true prompt row is the pane's last non-blank line" (as #52
# left it) stopped holding once Claude Code started rendering the model/mode
# footer BELOW the input box — the true last line became the footer, which
# never carries the glyph, so a real draft above it went undetected forever
# (the master-draft-swallow bug). The true prompt row is instead the LAST line
# whose visible text matches the glyph at line start
# (^[[:space:]]*($TUI_INPUT_GLYPH_REGEX)); taking the last such match (not
# merely anchoring at line start) is still required to fail open on a
# completed table/box row that itself starts with the glyph (#52, and the
# harder "│ > 5 │ ok │" variant) when a real input box follows it lower in the
# pane. Selecting by glyph alone also made an empty box permanently report
# DRAFT: its filler is U+00A0 (NBSP), not an ASCII space, and this function's
# LC_ALL=C means [[:space:]] does not match it — so NBSP must be stripped
# before the blank check too. Both halves are required together: line-start
# selection alone regresses every idle master to a permanent false DRAFT
# (no #52 safety valve on the send-remote-control.sh path), and the NBSP fix
# alone does nothing without the row-selection fix to find the real input row
# in the first place.
#
# Issue #101: Claude Code's own suggested-next-prompt ghost text renders on this
# same input row once a turn ends, and it's model-generated prose -- no static
# placeholder pattern can match it, so #52's guard alone reported it as a real
# draft. The one reliable discriminator is color: the ghost suggestion renders
# dim (ESC[2m); real operator input renders bright (38;5;231 on 48;5;237).
#
# Issue #111: the first #101 fix used TWO independent notions of "which bytes
# are visible" -- strip_ansi() (regex substitution) to find the input line and
# compute $rest, and a separate byte-walking parser to locate the dim state at
# that offset. They agreed on CSI sequences but not on OSC (`ESC ] ... BEL`,
# which tmux emits verbatim for OSC-8 hyperlinks on 3.4+), charset selects, or
# SO/SI: strip_ansi() deletes the whole sequence, the old walker consumed only
# the leading ESC byte and counted the rest as visible text. That let the
# visible-byte counter run ahead of the true offset and read the dim state at
# the wrong position -- concretely, a real bright draft preceded by a dim run
# and an OSC-8 hyperlink could misreport NO DRAFT, the dangerous direction
# (the heartbeat would then paste over the operator's unsent input). Adding
# another escape class to the old walker would only have deferred the next
# drift; the durable fix is ONE pass that produces both the stripped line and
# the SGR state at every offset in it, so "visible byte" has exactly one
# definition inside this guard. _pane_scan_lines() below is that one pass, and
# strip_ansi() is not consulted here at all any more.
#
# Issue #112: the prior version cost ~7 forks per call on the draft path --
# strip_ansi() (perl), grep|tail|cut to find the input line, two sed -n calls
# to extract it, then a second perl fork for the dim walk. _pane_scan_lines()
# folds all of that into a single perl invocation.
#
# rv101 review (kept here because it's load-bearing, not just history):
#  1. A substring match for the literal bytes "2m" also matches truecolor's
#     EXTENDED-COLOUR INTRODUCER (ESC[38;2;R;G;Bm) -- the "2" there means "the
#     next 3 params are an RGB triple", not dim, and a real bright draft on a
#     truecolor terminal would have been misread as ghost text and force-
#     delivered over. _pane_scan_lines() below properly tokenizes SGR
#     parameters and skips the trailing args 38/48/58 consume (5;n or
#     2;r;g;b) instead of treating every token as a standalone attribute.
#  2. "dim ANYWHERE on the row" is not "the operator's own text is dim": a
#     trailing dim right-aligned affordance, or -- the case this guard exists
#     for -- a partially-typed real draft with a dim ghost COMPLETION
#     continuing inline on the same row, must not suppress the real prefix.
#     The check is therefore scoped to the SGR state active at the exact byte
#     position where "$rest" (the text right after the glyph) begins, not the
#     row as a whole.
#  3. An EMPTY raw (-e) capture is ambiguous between "-e itself is rejected by
#     an ancient tmux" (capture-pane -e dates to tmux 1.8) and "the pane truly
#     has nothing to show". Collapsing both to "no draft" would silently lose
#     the pre-#101 protection on any tmux old enough to reject -e. A plain
#     (no -e) retry disambiguates: if that succeeds, this degrades to exactly
#     the #52-only (no color) result; only if BOTH captures are empty is there
#     really nothing there.
#
# Fails toward "draft" (today's over-detection), not toward "no draft", when
# color can't be read at all: the dim check only ever SUPPRESSES a draft
# classification the checks above already reached; it never independently
# asserts one. No positive dim evidence just means the #52 result stands as-is,
# which is the deliberate direction here -- silently clobbering a real unsent
# operator draft is worse than an occasional late/duplicate heartbeat nudge
# from over-detecting a ghost suggestion, and that's exactly the failure mode
# this guard already tolerated before #101 existed.
pane_has_draft() { # <target>  -> 0 ONLY if the true input row (last glyph line) holds unsent operator text
  local LC_ALL=C   # byte-count ${#...} below, not locale-dependent char counts
  local raw scanned sep out_line line mask found=0 last_line="" last_mask=""

  # rv142: the window has to be tall enough to still contain the input row of a
  # MULTI-LINE draft. The glyph renders only on the draft's FIRST row, so a
  # 15-line window loses it as soon as the draft wraps past ~12 rows (the
  # model/mode footer eats the rest) -- found=0, "no draft", and the heartbeat
  # pastes straight over it. That is precisely #141's reported shape: a long
  # orchestrator brief typed into master. Widening only ever ADDS rows above
  # the ones already scanned, and the row-selection below takes the LAST glyph
  # row, so the row chosen for a pane that already had one is unchanged; the
  # only new outcomes are on panes that previously found no glyph row at all,
  # and those move toward the fail-safe ("draft") direction.
  raw="$(tmux capture-pane -t "$1" -p -e 2>/dev/null | tail -n "$TUI_DRAFT_SCAN_LINES")"
  if [ -z "$raw" ]; then
    raw="$(tmux capture-pane -t "$1" -p 2>/dev/null | tail -n "$TUI_DRAFT_SCAN_LINES")"
    [ -n "$raw" ] || return 1
  fi

  scanned="$(printf '%s\n' "$raw" | _pane_scan_lines)"
  [ -n "$scanned" ] || return 1

  # Issue #141: current Claude Code renders the model/mode footer BELOW the
  # input box, so the true prompt row is no longer "the last non-blank pane
  # line" (that's the footer now, e.g. the "bypass permissions" hint) --
  # it's the LAST line whose VISIBLE text carries the glyph AT LINE START.
  # Taking the last such match (not the first) is what keeps a completed
  # table/box row that happens to start with the glyph (#52, and the harder
  # "│ > 5 │ ok │" variant) from being mistaken for the live input row when a
  # real (possibly empty) input box still follows it lower in the pane.
  sep="$(printf '\x01')"
  while IFS= read -r out_line; do
    line="${out_line%%"$sep"*}"
    mask="${out_line#*"$sep"}"
    if [[ "$line" =~ ^[[:space:]]*($TUI_BOX_BORDER_REGEX)?($TUI_INPUT_GLYPH_REGEX) ]]; then
      last_line="$line"
      last_mask="$mask"
      found=1
    fi
  done <<SCANEOF
$scanned
SCANEOF
  [ "$found" -eq 1 ] || return 1

  [[ "$last_line" =~ ^[[:space:]]*($TUI_BOX_BORDER_REGEX)?($TUI_INPUT_GLYPH_REGEX)[[:space:]]?(.*)$ ]] || return 1
  local rest="${BASH_REMATCH[3]}"
  # Issue #141: an empty input box's filler is U+00A0 (NBSP, byte C2 A0), not
  # an ASCII space -- LC_ALL=C means [[:space:]] does not match it, so a
  # genuinely empty box would otherwise report DRAFT permanently. Strip NBSP
  # bytes before the blank check; the offset math below still uses the
  # unstripped $rest, so it stays correct.
  local rest_no_nbsp="${rest//$'\xc2\xa0'/}"
  # ...and when the input box is drawn with side borders, the row's trailing
  # "│" is part of the frame, not operator text: without discounting it an
  # empty boxed row ("│ ❯      │") would report DRAFT forever, the same
  # permanent false positive the NBSP strip above exists to prevent.
  [[ "$rest_no_nbsp" =~ ^[[:space:]]*($TUI_BOX_BORDER_CLOSE_REGEX)?[[:space:]]*$ ]] && return 1
  # The placeholder allow-list is anchored at the start of $rest, and only ONE
  # ASCII space was consumed as the glyph/text separator above -- so on a build
  # that pads the box with NBSP the hint would read as "<NBSP>for shortcuts",
  # miss the allow-list entirely, and every idle master would report a
  # permanent false DRAFT (#52's requeue-forever). Test the NBSP-stripped copy
  # as well; leading ASCII space is deliberately NOT trimmed, so this widens
  # the allow-list only for the filler byte, never toward clobbering a draft.
  { [[ "$rest" =~ $TUI_DRAFT_PLACEHOLDER_REGEX ]] || [[ "$rest_no_nbsp" =~ $TUI_DRAFT_PLACEHOLDER_REGEX ]]; } && return 1

  local off=$(( ${#last_line} - ${#rest} ))
  [ "${last_mask:$off:1}" = "1" ] && return 1
  return 0
}

# The one pass issues #111/#112 ask for: reads the multi-line raw (possibly
# -e/color) capture on stdin and, per line, emits the stripped (visible-only)
# text and a same-length mask of '1'/'0' marking whether the SGR dim/faint
# attribute (ECMA-48 code 2) is active at each visible byte -- separated by a
# literal \x01 byte (any \x01 that shows up in the visible text itself is
# sanitized to a space so it can never collide with the separator). This is
# the ONLY
# place that decides which raw bytes are "visible": there is no second,
# independently-maintained notion (like strip_ansi()'s regexes) for
# pane_has_draft() to drift out of sync with, which is what issue #111 was
# about. Recognizes exactly the four escape classes strip_ansi() does -- CSI
# (`ESC [ ... final-byte`), OSC (`ESC ] ... BEL` or `ESC ] ... ESC \`), charset
# selects (`ESC ( X` / `ESC ) X`), and SO/SI (`\x0e`/`\x0f`) -- as zero-width,
# and everything else (including an escape byte that doesn't complete one of
# those four shapes before end of line) as literal visible text, matching
# strip_ansi()'s "no match, no deletion" behavior. SGR ("m"-terminated CSI)
# parameters are parsed properly so 38/48/58's trailing 5;n or 2;r;g;b
# arguments are consumed rather than misread as standalone attribute codes (rv101
# finding 1), and %active resets at the start of every line, same as the
# per-line walker this replaces (rv101 finding 2's per-row scoping still
# holds: dim state is whatever it is exactly at each visible byte, not
# smeared across the row).
_pane_scan_lines() {
  perl -e '
    local $/;
    my $raw = <STDIN>;
    $raw = "" unless defined $raw;
    for my $raw_line (split(/\n/, $raw, -1)) {
      my %active;
      my $stripped = "";
      my $mask = "";
      my $i = 0;
      my $len = length($raw_line);
      while ($i < $len) {
        my $c = substr($raw_line, $i, 1);
        if ($c eq "\x1b") {
          my $c2 = $i + 1 < $len ? substr($raw_line, $i + 1, 1) : "";
          if ($c2 eq "[") {
            my $j = $i + 2;
            my $csi_ok = 1;
            while ($j < $len) {
              my $cj = substr($raw_line, $j, 1);
              last if $cj =~ /[A-Za-z]/;
              if ($cj !~ /[0-9;:?<=>]/) { $csi_ok = 0; last; }
              $j++;
            }
            if ($csi_ok && $j < $len) {
              my $final = substr($raw_line, $j, 1);
              if ($final eq "m") {
                my $params = substr($raw_line, $i + 2, $j - ($i + 2));
                my @toks = length($params) ? split(/;/, $params, -1) : ("0");
                my $k = 0;
                while ($k <= $#toks) {
                  my $p = $toks[$k];
                  $p = "0" if $p eq "";
                  if ($p eq "0") { %active = (); }
                  elsif ($p eq "22") { delete $active{2}; }
                  elsif ($p eq "38" || $p eq "48" || $p eq "58") {
                    my $mode = defined($toks[$k + 1]) ? $toks[$k + 1] : "";
                    if ($mode eq "5") { $k += 2; }
                    elsif ($mode eq "2") { $k += 4; }
                  } else {
                    $active{$p} = 1;
                  }
                  $k++;
                }
              }
              $i = $j + 1;
              next;
            }
            $stripped .= $c;
            $mask .= (exists $active{2} ? "1" : "0");
            $i++;
            next;
          }
          if ($c2 eq "]") {
            my $j = $i + 2;
            my $term_end = -1;
            while ($j < $len) {
              my $cj = substr($raw_line, $j, 1);
              if ($cj eq "\x07") { $term_end = $j + 1; last; }
              if ($cj eq "\x1b") {
                if ($j + 1 < $len && substr($raw_line, $j + 1, 1) eq "\\") { $term_end = $j + 2; }
                last;
              }
              $j++;
            }
            if ($term_end >= 0) {
              $i = $term_end;
              next;
            }
            $stripped .= $c;
            $mask .= (exists $active{2} ? "1" : "0");
            $i++;
            next;
          }
          if ($c2 eq "(" || $c2 eq ")") {
            my $c3 = $i + 2 < $len ? substr($raw_line, $i + 2, 1) : "";
            if ($c3 ne "" && $c3 =~ /[0-9A-Za-z]/) {
              $i += 3;
              next;
            }
            $stripped .= $c;
            $mask .= (exists $active{2} ? "1" : "0");
            $i++;
            next;
          }
          $stripped .= $c;
          $mask .= (exists $active{2} ? "1" : "0");
          $i++;
          next;
        }
        if ($c eq "\x0e" || $c eq "\x0f") { $i++; next; }
        $stripped .= $c;
        $mask .= (exists $active{2} ? "1" : "0");
        $i++;
      }
      $stripped =~ s/\x01/ /g;  # never let literal pane text collide with our \x01 separator
      print $stripped, "\x01", $mask, "\n";
    }
  '
}

# Deliver text into a pane reliably:
#  - load-buffer/paste-buffer handles multiline (send-keys breaks on newlines)
#  - a buffer name unique per call (target + pid + $RANDOM + a call counter) so two
#    concurrent sends to the same target (e.g. a watchdog nudge racing `orch send`)
#    never collide on the same tmux buffer (issue #14)
#  - -p -d pastes bracketed then deletes the buffer; Enter is gated on that delete
#    actually landing (polled via `show-buffer`) instead of a fixed timing guess
: "${_SEND_PROMPT_SEQ:=0}"
# Single source of truth for both defaults, so a value edited in one place
# can't drift out of sync with the "using ..." message that reports it
# (issue #135 polish item 1). Plain assignments, deliberately NOT `:=`: these
# are the trusted values the invalid-override fallback resets to and are never
# themselves re-validated, so an inherited `_ORCH_SEND_POLL_TRIES_DEFAULT=abc`
# in the environment would turn the fallback into the very unbounded hang the
# sanitising below exists to prevent.
_ORCH_SEND_POLL_TRIES_DEFAULT=50
_ORCH_SEND_POLL_INTERVAL_DEFAULT=0.1
# `${VAR=...}` (no colon) so an explicitly-empty override survives to the
# per-call validation below and is reported as invalid, instead of being
# silently swallowed into the default here (issue #135 polish item 2).
: "${ORCH_SEND_POLL_TRIES=$_ORCH_SEND_POLL_TRIES_DEFAULT}"       # poll count cap
: "${ORCH_SEND_POLL_INTERVAL=$_ORCH_SEND_POLL_INTERVAL_DEFAULT}" # seconds slept between polls (issue #135)
send_prompt() { # <target> <text...>
  local target="$1"; shift
  local text="$*"
  _SEND_PROMPT_SEQ=$((_SEND_PROMPT_SEQ + 1))
  local buf="b-${target//[^a-zA-Z0-9]/_}-$$-${RANDOM}-${_SEND_PROMPT_SEQ}"
  printf '%s' "$text" | tmux load-buffer -b "$buf" -
  tmux paste-buffer -p -d -b "$buf" -t "$target"
  # -d deletes the buffer once the paste is delivered; poll for that instead of
  # a blind sleep, capped so a stuck/renamed buffer can never hang the send.
  # Sanitise the cap into a local first. Anything `[ -ge ]` cannot compare as an
  # integer (empty or non-numeric) makes the test error out on every iteration
  # so the cap never fires, reinstating exactly the unbounded hang it exists to
  # prevent; a zero/leading-zero value ("0", "00") gives up on the very first
  # poll and sends Enter ungated. Demand a plain positive decimal of at most 6
  # digits -- a deliberate sanity cap (999999 polls ~= 28h, far past any real
  # use), not a bash-intmax boundary -- and fall back to the default otherwise.
  # `${VAR-}` (not `${VAR:-}`) so a caller-supplied *empty* override falls
  # through to the `''` case arm below as an explicit invalid value, rather
  # than being silently swallowed into the default (issue #135 polish item 2).
  local tries="${ORCH_SEND_POLL_TRIES-}"
  local tries_ok=1
  case "$tries" in
    ''|*[!0-9]*|0*) tries_ok=0 ;;
    *) [ "${#tries}" -le 6 ] || tries_ok=0 ;;
  esac
  if [ "$tries_ok" -eq 0 ]; then
    say "send_prompt: ignoring invalid ORCH_SEND_POLL_TRIES='$tries'; using $_ORCH_SEND_POLL_TRIES_DEFAULT" >&2
    tries=$_ORCH_SEND_POLL_TRIES_DEFAULT
  fi
  # Same idiom for the sleep interval between polls (issue #135). Unlike the
  # poll count, a legitimate interval routinely starts with "0" (the "0.1"
  # default itself), so "starts with 0" can't be the malformed test here --
  # the real degenerate case is a value that is numerically zero (spins the
  # loop with no delay) or a shape `sleep` can't parse as a plain decimal.
  # The `.*` arm deliberately rejects the leading-dot spelling (`.5`) even
  # though `sleep` itself accepts it: `0.5` is the canonical form and is
  # already accepted, so allowing both buys an operator nothing and widens
  # the shape this has to keep guaranteeing. A rejected `.5` is not silent --
  # it warns and falls back to the default like any other malformed value.
  # The whole-seconds part is capped at two digits for the same reason the poll
  # count is capped at six: without a magnitude bound the knob reinstates the
  # unbounded hang the cap exists to prevent. `${#interval} -le 9` bounds only
  # the *string*, so a shape-valid "999999999" would sleep ~31 years per poll
  # and 50 polls would never return. <=99s per poll keeps the *default* 50-poll
  # worst case at ~82min instead of unbounded. Note the two knobs multiply: an
  # operator who deliberately maxes both (999999 polls x 99s) still buys years,
  # so this is a guard against an accidentally absurd interval, not a global
  # ceiling on how long a caller can ask send_prompt to wait.
  local interval="${ORCH_SEND_POLL_INTERVAL-}"
  local interval_ok=1 interval_whole
  case "$interval" in
    ''|*[!0-9.]*|*.*.*|.*|*.) interval_ok=0 ;;
    *)
      [[ "$interval" =~ [1-9] ]] || interval_ok=0
      [ "${#interval}" -le 9 ] || interval_ok=0
      interval_whole="${interval%%.*}"
      [ "${#interval_whole}" -le 2 ] || interval_ok=0
      ;;
  esac
  if [ "$interval_ok" -eq 0 ]; then
    say "send_prompt: ignoring invalid ORCH_SEND_POLL_INTERVAL='$interval'; using $_ORCH_SEND_POLL_INTERVAL_DEFAULT" >&2
    interval=$_ORCH_SEND_POLL_INTERVAL_DEFAULT
  fi
  local i=0
  while tmux show-buffer -b "$buf" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge "$tries" ]; then
      say "send_prompt: paste buffer $buf still present after $tries polls; sending Enter ungated" >&2
      break
    fi
    sleep "$interval"
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
    command -v "$dep" >/dev/null 2>&1 || { say "missing dependency: $dep" >&2; missing=1; }
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
    exec 200>"$lock" || { say "with_lock: cannot open lock file $lock" >&2; return 1; }
    if ! flock -x -w "$ORCH_LOCK_TIMEOUT" 200; then
      say "with_lock: timed out waiting for lock $lock (flock)" >&2
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
      say "with_lock: timed out waiting for lock $lock (mkdir)" >&2
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
