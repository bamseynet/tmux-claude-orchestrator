#!/usr/bin/env bash
# _orch/update.sh — self-update (issue #91).
#   ./orch update [--check] [--force]   imperative, primary interface
#   _orch/update.sh --daily-check       throttled background check, invoked
#                                       once per heartbeat tick
#
# "Latest" is the VERSION file on upstream's default branch (fetched via
# `gh api repos/<repo>/contents/VERSION` with the raw media type, falling back
# to `curl` against raw.githubusercontent.com when gh is unavailable — no new
# dependency, since git/gh are already assumed and curl is used in CI). The
# repo has no tags/releases today, and VERSION is already this toolkit's
# authoritative version file (install.sh already stamps .orch-version from
# it), so reusing it needs no new tagging discipline. Every fetch is
# time-capped (via `timeout`/`gtimeout`, or a portable wait+kill fallback when
# neither exists — see _run_timeout) so it can never hang an interactive
# command, on any of Linux/macOS/BSD.
#
# Applying an update shallow-clones upstream to a scratch dir and hands it to
# install.sh exactly like a manual reinstall would — reusing its existing
# idempotent copy + config.json-preserving logic rather than reimplementing
# the copy here.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

UPDATE_STATE="$STATE_DIR/update-check.json"
FETCH_TIMEOUT="${ORCH_UPDATE_FETCH_TIMEOUT:-5}"
CLONE_TIMEOUT="${ORCH_UPDATE_CLONE_TIMEOUT:-30}"

_run_timeout() { # <seconds> <cmd...> -- caps a command; NEVER runs it uncapped
  if command -v timeout >/dev/null 2>&1; then
    timeout "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$@"
    return $?
  fi
  # Neither timeout(1) nor gtimeout(1) is present (e.g. stock macOS, which
  # ships neither by default). `curl --max-time` self-caps regardless, but
  # `gh` has no such flag — so a missing timeout binary must never mean an
  # unbounded network call. Enforce the cap ourselves: run the command in the
  # background, race a killer against it, and use whichever finishes first.
  #
  # `set -m` puts the backgrounded command in its OWN process group so the
  # killer can signal the whole group (`kill -- -PID`), not just its top PID.
  # Without this, killing only the top PID (e.g. `gh`, a wrapper script) can
  # leave a child of its own (a `curl`/`git` it spawned) alive and orphaned —
  # and since that orphan still holds the very pipe fd this command
  # substitution is reading from, the caller hangs waiting for EOF on it long
  # after the top-level process is gone, for as long as the orphan runs. TERM
  # first (lets a well-behaved client clean up), then KILL the group shortly
  # after in case TERM was ignored/blocked.
  local secs="$1"; shift
  local old_monitor; case "$-" in *m*) old_monitor=1 ;; *) old_monitor=0 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  ( set +m; sleep "$secs" 2>/dev/null
    kill -TERM -- "-$cmd_pid" 2>/dev/null
    sleep 0.2
    kill -KILL -- "-$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -KILL -- "-$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  [ "$old_monitor" = 1 ] || set +m
  return "$rc"
}

# jq's `// default` treats `false` and `0` as absent, which would silently
# flip enabled:false to enabled:true / interval_hours:0 to 24 — so these read
# the raw value (jq prints the literal string "null" for a missing key) and
# apply the default in bash instead of via `//`.
_cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; } # <jq filter> -> value, or "null"/empty

update_repo() { local r; r="$(_cfg '.update.repo')"; [ -n "$r" ] && [ "$r" != null ] && echo "$r" || echo "bamseynet/tmux-claude-orchestrator"; }
update_branch() { local b; b="$(_cfg '.update.branch')"; [ -n "$b" ] && [ "$b" != null ] && echo "$b" || echo "main"; }
# Fails CLOSED (disabled, logged) when config.json itself can't be parsed at
# all (missing file, invalid JSON) — a corrupt config must never silently turn
# network checks ON. A valid config that simply omits update.enabled defaults
# to on, matching the shipped config.json.
update_enabled() {
  local e
  if ! e="$(jq -r '.update.enabled' "$CONFIG" 2>/dev/null)"; then
    log "update: could not read/parse $CONFIG — checks disabled (failing closed)"
    return 1
  fi
  [ "$e" != "false" ]
}
# A non-integer (e.g. "0.5") blows up `$(( interval_h * 3600 ))` below (a
# bash arithmetic syntax error), and a genuinely unset/unbound value under
# `set -u` does too — either would kill --daily-check before it ever reaches
# _write_state, so no update-check.json gets written, so heartbeat.sh's own
# mtime pre-filter never sees a "recently checked" file and re-forks this
# script (and re-fetches over the network) on EVERY tick instead of once a
# day. Same sanitization heartbeat.sh applies inline to its own copy of this
# value; validate here too so update.sh is correct standalone, not just when
# called from heartbeat.
update_interval_hours() {
  local h; h="$(_cfg '.update.interval_hours')"
  case "$h" in
    ''|null) echo 24; return ;;
    *[!0-9]*) echo 24; return ;;
  esac
  echo "$h"
}

current_version() {
  if [ -f "$ORCH_ROOT/.orch-version" ]; then cat "$ORCH_ROOT/.orch-version"
  elif [ -f "$ORCH_ROOT/VERSION" ]; then cat "$ORCH_ROOT/VERSION"
  else echo unknown; fi
}

# Prints upstream's VERSION-file content on stdout; non-zero exit on any
# failure (offline, gh/curl missing, bad repo/branch, or a response that
# isn't a bare version string). Hard-capped at $FETCH_TIMEOUT seconds either
# way — never hangs.
#
# Any 200-with-a-body is trusted as "the file" by both gh and curl -fsSL — an
# old gh ignoring the raw-media-type Accept header (JSON envelope instead of
# raw bytes), or an SSO/captive-portal page answering with its own 200 body
# instead of the real GitHub response, would otherwise become "the latest
# version" outright: reported to the user, persisted to update-check.json,
# and (without --check) fed straight into a clone+install. Validate the shape
# before trusting it — anything that isn't a bare dotted-integer version
# string is treated as a failed fetch, same as no response at all.
_looks_like_version() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; } # <string>
fetch_latest_version() {
  local repo branch out v
  repo="$(update_repo)"; branch="$(update_branch)"
  if command -v gh >/dev/null 2>&1; then
    # Ask for the raw media type so gh hands back the file's bytes directly —
    # avoids base64-decoding the default JSON-wrapped response entirely
    # (GNU base64's -d flag is not portable to BSD/macOS base64, which wants
    # -D; sidestepping the decode sidesteps that portability trap too).
    out="$(_run_timeout "$FETCH_TIMEOUT" gh api -H "Accept: application/vnd.github.raw" \
      "repos/$repo/contents/VERSION?ref=$branch" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    v="$(printf '%s' "$out" | tr -d '[:space:]')"
    _looks_like_version "$v" || return 1
    printf '%s' "$v"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    out="$(_run_timeout "$FETCH_TIMEOUT" curl -fsSL --max-time "$FETCH_TIMEOUT" \
      "https://raw.githubusercontent.com/$repo/$branch/VERSION" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    v="$(printf '%s' "$out" | tr -d '[:space:]')"
    _looks_like_version "$v" || return 1
    printf '%s' "$v"
    return 0
  fi
  return 1
}

# 0 if <latest> is newer than <current> (semver-ish; uses `sort -V`).
_is_newer() { # <current> <latest>
  [ "$1" != "$2" ] || return 1
  # `sort -V` ranks the word "unknown" above any real dotted-integer version
  # (it sorts lexically once it can't parse a component as a number), so an
  # install with no .orch-version/VERSION stamp at all would report "local
  # version (unknown) is newer than upstream" forever and could never update.
  # current_version() only ever returns "unknown" in that exact no-stamp
  # case, so treat it as the oldest possible version instead of the newest.
  [ "$1" = unknown ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]
}

_write_state() { # <current> <latest> <checked_ok 0/1> <error> <update_available 0/1> <notified_version>
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local tmp="$UPDATE_STATE.tmp.$$"
  if jq -n \
    --arg cur "$1" --arg latest "$2" \
    --argjson ok "$([ "$3" = 1 ] && echo true || echo false)" \
    --arg err "$4" \
    --argjson upd "$([ "$5" = 1 ] && echo true || echo false)" \
    --arg notified "$6" \
    --argjson now_epoch "$(date +%s)" --arg now_iso "$(date -u +%FT%TZ)" \
    '{last_checked_epoch: $now_epoch, last_checked: $now_iso, current_version: $cur,
      latest_version: $latest, checked_ok: $ok, error: $err, update_available: $upd,
      notified_version: $notified}' > "$tmp" 2>/dev/null && mv -f "$tmp" "$UPDATE_STATE" 2>/dev/null; then
    return 0
  fi
  # Could not persist the full state (e.g. an unwritable state dir). Still
  # touch the path so heartbeat.sh's mtime pre-filter sees a "recently
  # checked" file and doesn't fire again next tick — without this, a
  # persistently-failing write would silently re-fetch over the network (and
  # re-fork this whole script) on EVERY heartbeat tick forever, exactly the
  # retry storm the mtime throttle exists to prevent.
  rm -f "$tmp" 2>/dev/null || true
  : > "$UPDATE_STATE" 2>/dev/null || true
  return 1
}

# Live-worker / session guard (the actual hazard here: heartbeat/watchdog loops
# re-invoke _orch/*.sh continuously and workers are live processes, so rewriting
# those scripts out from under them mid-run is unsafe). Refuses by default;
# --force is the deliberate escape hatch, same convention as merge.sh's --auto.
_update_would_disrupt_live_session() {
  local live=0
  live="$(live_worker_count 2>/dev/null || echo 0)"
  [ "$live" -gt 0 ] && return 0
  # require_valid_session_name (issue #92 rv92) right before interpolating
  # $SESSION_NAME into a tmux target, same convention as clean.sh/watchdog.sh/
  # etc. — an imperative, single-shot command like `orch update` is exactly
  # the kind of caller lib.sh's own comment says should hard-exit on an
  # invalid session name rather than silently targeting the wrong pane.
  command -v tmux >/dev/null 2>&1 || return 1
  require_valid_session_name
  tmux has-session -t "$SESSION_NAME" 2>/dev/null && return 0
  return 1
}

_apply_update() { # <target-version>
  local repo branch tmpdir target="$1" rc=0
  repo="$(update_repo)"; branch="$(update_branch)"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/orch-update.XXXXXX")"

  say "orch update: fetching $repo@$branch..."
  if ! _run_timeout "$CLONE_TIMEOUT" git clone --quiet --depth 1 --branch "$branch" \
      "https://github.com/$repo.git" "$tmpdir" 2>/dev/null; then
    say "orch update: failed to clone upstream ($repo@$branch) — nothing changed." >&2
    rm -rf "$tmpdir"
    return 1
  fi
  if [ ! -f "$tmpdir/install.sh" ]; then
    say "orch update: cloned copy has no install.sh — nothing changed." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  local before; before="$(current_version)"
  if bash "$tmpdir/install.sh" "$ORCH_ROOT"; then
    say "orch update: updated $before -> $target. Background loops were NOT restarted — run './orch down' then './orch up' to pick up the new scripts."
  else
    rc=$?
    say "orch update: install.sh failed (exit $rc) applying the update." >&2
  fi
  rm -rf "$tmpdir"
  return "$rc"
}

daily_check() {
  if ! update_enabled; then
    log "update: daily check disabled by config"
    return 0
  fi
  local interval_h now last interval_s
  interval_h="$(update_interval_hours)"
  interval_s=$(( interval_h * 3600 ))
  now="$(date +%s)"
  last="$(jq -r '.last_checked_epoch // 0' "$UPDATE_STATE" 2>/dev/null || echo 0)"
  if [ -f "$UPDATE_STATE" ] && [ "$last" -gt 0 ] && [ $(( now - last )) -lt "$interval_s" ]; then
    return 0   # throttled: still within the window, no network call
  fi

  local cur latest ok=1 err="" update_available=0 notified=""
  cur="$(current_version)"
  if latest="$(fetch_latest_version)"; then
    if _is_newer "$cur" "$latest"; then
      update_available=1
      local prev_notified
      prev_notified="$(jq -r '.notified_version // empty' "$UPDATE_STATE" 2>/dev/null || true)"
      if [ "$prev_notified" != "$latest" ]; then
        log "update: update available: $cur -> $latest (run './orch update')"
      fi
      notified="$latest"
    fi
  else
    ok=0
    err="fetch failed (network unreachable, or gh/curl unavailable)"
    log "update: daily check failed: $err"
  fi
  _write_state "$cur" "${latest:-}" "$ok" "$err" "$update_available" "$notified" || true
  return 0   # never fails the caller (heartbeat's loop) on a network hiccup
}

cmd_update() {
  local check_only=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check_only=1; shift ;;
      --force) force=1; shift ;;
      *) say "update: unexpected arg: $1" >&2; exit 1 ;;
    esac
  done

  local cur latest
  cur="$(current_version)"
  say "orch update: current version: $cur"

  if ! latest="$(fetch_latest_version)"; then
    say "orch update: could not reach upstream (network unreachable, or gh/curl unavailable) — nothing changed." >&2
    _write_state "$cur" "" 0 "fetch failed" 0 "" || true
    exit 1
  fi
  say "orch update: latest upstream version: $latest"

  if [ "$latest" = "$cur" ]; then
    say "orch update: already up to date."
    _write_state "$cur" "$latest" 1 "" 0 "" || true
    exit 0
  fi
  if ! _is_newer "$cur" "$latest"; then
    say "orch update: local version ($cur) is newer than upstream ($latest) — nothing to do."
    _write_state "$cur" "$latest" 1 "" 0 "" || true
    exit 0
  fi

  say "orch update: update available: $cur -> $latest"
  _write_state "$cur" "$latest" 1 "" 1 "$latest" || true

  if [ "$check_only" = 1 ]; then
    say "orch update: --check specified, not applying."
    exit 0
  fi

  if [ "$force" != 1 ] && _update_would_disrupt_live_session; then
    say "orch update: refusing to apply — live worker(s) and/or the tmux session ($SESSION_NAME) is up." >&2
    say "  './orch update' rewrites _orch/*.sh and orch out from under any running heartbeat/watchdog loop" >&2
    say "  and live worker panes, which is unsafe while they're running. Either './orch down' and let/clean" >&2
    say "  workers finish first, or re-run with --force (you must './orch down' && './orch up' afterward" >&2
    say "  yourself — --force does not restart anything for you)." >&2
    exit 1
  fi

  _apply_update "$latest"
}

case "${1:-}" in
  --daily-check) daily_check ;;
  *) cmd_update "$@" ;;
esac
