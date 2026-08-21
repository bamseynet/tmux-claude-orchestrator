#!/usr/bin/env bats
# Hermetic tests for _orch/update.sh (issue #91): self-update — imperative
# `orch update` / `--check`, and the throttled background `--daily-check` the
# heartbeat loop invokes. `gh`/`curl` are fully stubbed (no real network call,
# ever); `git` is stubbed only for `clone` (delegating everything else to the
# real git binary) so the update-apply path can exercise a real install.sh
# without ever touching the network.

UPDATE="$BATS_TEST_DIRNAME/../_orch/update.sh"
SRC="$BATS_TEST_DIRNAME/.."

setup() {
  REALGIT="$(command -v git)"
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  GIT_CLONE_LOG="$BATS_TEST_TMPDIR/git-clone.log"
  : > "$GH_LOG"
  : > "$GIT_CLONE_LOG"
  export GH_LOG GIT_CLONE_LOG

  # GH_VERSION=<val>   -> content of upstream VERSION file gh/curl "fetch"
  # GH_FAIL=1          -> gh api call fails (simulates network/API failure)
  cat > "$STUBBIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
if [ "\${GH_FAIL:-0}" = "1" ]; then
  echo "gh: network unreachable" >&2
  exit 1
fi
if [ "\$1" = "api" ]; then
  printf '%s' "\${GH_VERSION:-0.1.0}"
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBBIN/gh"

  # Clones a throwaway upstream copy (real repo files, so install.sh applies
  # for real) instead of ever touching the network.
  cat > "$STUBBIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "clone" ]; then
  echo "git \$*" >> "$GIT_CLONE_LOG"
  if [ "\${GIT_CLONE_FAIL:-0}" = "1" ]; then
    echo "git: could not resolve host" >&2
    exit 1
  fi
  dest="\${*: -1}"
  mkdir -p "\$dest"
  cp -R "$SRC/_orch" "\$dest/"
  cp -R "$SRC/tmux" "\$dest/"
  cp "$SRC/orch" "\$dest/"
  cp "$SRC/install.sh" "\$dest/"
  printf '%s' "\${GH_VERSION:-0.1.0}" > "\$dest/VERSION"
  exit 0
fi
exec "$REALGIT" "\$@"
EOF
  chmod +x "$STUBBIN/git"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  has-session) exit "${TMUX_SESSION_UP:-1}" ;;
  list-sessions)
    [ "${TMUX_SESSION_UP:-1}" = "0" ] && echo "${SESSION_NAME:-orch-test}"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  PATH="$STUBBIN:$PATH"
  export PATH

  ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export ORCH_ROOT
  mkdir -p "$ORCH_ROOT/_orch/state"
  cat > "$ORCH_ROOT/_orch/config.json" <<'JSON'
{
  "update": {
    "enabled": true,
    "interval_hours": 24,
    "repo": "bamseynet/tmux-claude-orchestrator",
    "branch": "main"
  }
}
JSON
  echo "0.1.0" > "$ORCH_ROOT/VERSION"
  echo "0.1.0" > "$ORCH_ROOT/.orch-version"
  export SESSION_NAME="orch-test"
}

# --- orch update --check ------------------------------------------------------

@test "orch update --check reports an available update without applying it" {
  GH_VERSION=0.2.0 run "$UPDATE" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"0.1.0"* ]]
  [[ "$output" == *"0.2.0"* ]]
  [[ "$output" == *"update available"* ]]
  [ ! -s "$GIT_CLONE_LOG" ]
  [ "$(cat "$ORCH_ROOT/.orch-version")" = "0.1.0" ]
}

@test "orch update --check reports already current when versions match" {
  GH_VERSION=0.1.0 run "$UPDATE" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
  [ ! -s "$GIT_CLONE_LOG" ]
}

@test "orch update --check does not apply even when workers are live" {
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  echo '{"status":"working"}' > "$ORCH_ROOT/_orch/state/workers/w1.json"
  GH_VERSION=0.2.0 run "$UPDATE" --check
  [ "$status" -eq 0 ]
  [ ! -s "$GIT_CLONE_LOG" ]
}

# --- network failure: never fatal, never hangs --------------------------------

@test "orch update --check handles network failure without crashing" {
  GH_FAIL=1 run timeout 10 "$UPDATE" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not reach upstream"* || "$output" == *"network"* ]]
  [ ! -s "$GIT_CLONE_LOG" ]
}

@test "fetch is still time-capped when neither timeout nor gtimeout is on PATH (portable fallback)" {
  # Stock macOS ships neither timeout(1) nor gtimeout(1) by default. `gh` has
  # no built-in cap of its own (unlike curl's --max-time), so without a
  # portable fallback a stalled gh call would hang forever — exactly the
  # failure mode issue #91's safety section forbids.
  NOTIMEOUT="$BATS_TEST_TMPDIR/notimeout"
  mkdir -p "$NOTIMEOUT"
  for bin in bash sh env cat mkdir rm cp chmod echo grep touch dirname basename \
             jq mv date sort tr printf mktemp kill sleep; do
    p="$(command -v "$bin" 2>/dev/null)" && ln -sf "$p" "$NOTIMEOUT/$bin"
  done
  ln -sf "$STUBBIN/git" "$NOTIMEOUT/git"
  ln -sf "$STUBBIN/tmux" "$NOTIMEOUT/tmux"
  cat > "$NOTIMEOUT/gh" <<'EOF'
#!/usr/bin/env bash
sleep 30
echo "0.9.9"
EOF
  chmod +x "$NOTIMEOUT/gh"

  start="$(date +%s)"
  ORCH_UPDATE_FETCH_TIMEOUT=1 PATH="$NOTIMEOUT" run "$UPDATE" --check
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -ne 0 ]
  [ "$elapsed" -lt 10 ]
}

@test "orch update falls back to curl when gh is unavailable" {
  # Build a PATH with no `gh` at all (not just no stub — the real /usr/bin/gh
  # must not be reachable either), otherwise this doesn't actually exercise
  # the no-gh fallback branch.
  NOGH="$BATS_TEST_TMPDIR/nogh"
  mkdir -p "$NOGH"
  for bin in bash sh env cat mkdir rm cp chmod echo grep touch dirname basename \
             jq mv date base64 sort tr printf mktemp timeout; do
    p="$(command -v "$bin" 2>/dev/null)" && ln -sf "$p" "$NOGH/$bin"
  done
  ln -sf "$STUBBIN/git" "$NOGH/git"
  ln -sf "$STUBBIN/tmux" "$NOGH/tmux"
  cat > "$NOGH/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$GH_LOG"
printf '%s' "\${GH_VERSION:-0.1.0}"
EOF
  chmod +x "$NOGH/curl"
  GH_VERSION=0.3.0 PATH="$NOGH" run "$UPDATE" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"0.3.0"* ]]
}

# --- imperative apply ----------------------------------------------------------

@test "orch update applies the update via install.sh when no workers are live" {
  GH_VERSION=0.2.0 run "$UPDATE"
  [ "$status" -eq 0 ]
  [ -s "$GIT_CLONE_LOG" ]
  [ "$(cat "$ORCH_ROOT/.orch-version")" = "0.2.0" ]
}

@test "orch update preserves the local tuned config.json across an apply" {
  jq '.thresholds.max_workers = 99' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  jq '.update.enabled = true' "$ORCH_ROOT/_orch/config.json.tmp" > "$ORCH_ROOT/_orch/config.json"
  rm -f "$ORCH_ROOT/_orch/config.json.tmp"

  GH_VERSION=0.2.0 run "$UPDATE"
  [ "$status" -eq 0 ]
  run jq -r '.thresholds.max_workers' "$ORCH_ROOT/_orch/config.json"
  [ "$output" = "99" ]
}

@test "orch update refuses to apply when a worker is live, without --force" {
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  echo '{"status":"working"}' > "$ORCH_ROOT/_orch/state/workers/w1.json"
  GH_VERSION=0.2.0 run "$UPDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refus"* ]]
  [ ! -s "$GIT_CLONE_LOG" ]
  [ "$(cat "$ORCH_ROOT/.orch-version")" = "0.1.0" ]
}

@test "orch update refuses to apply when the tmux session is up, without --force" {
  TMUX_SESSION_UP=0 GH_VERSION=0.2.0 run "$UPDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refus"* ]]
  [ ! -s "$GIT_CLONE_LOG" ]
}

@test "orch update is NOT fooled by a DIFFERENT live session whose name is a prefix of SESSION_NAME (issue #96)" {
  # Real tmux's `has-session -t <name>` matches an unambiguous PREFIX (confirmed
  # against tmux 3.4), not just an exact name -- model that here so this stub is
  # never stricter than real tmux, same convention as
  # hygiene_session_namespace.bats / issue92_named_persistent_sessions.bats /
  # send_remote_control.bats. Only "billing" is actually live; this install's
  # own session ("bill") is NOT. A bare `tmux has-session -t bill` would still
  # exit 0 (prefix match against "billing") and _update_would_disrupt_live_session
  # would wrongly refuse to apply, believing THIS install's session is up when it
  # is really a stranger's. session_exists() must see through the prefix and let
  # the update proceed.
  export SESSION_NAME="bill"
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  has-session)
    [ "${3:-}" = "billing" ] && exit 0
    [[ "billing" == "${3:-}"* ]] && exit 0
    exit 1
    ;;
  list-sessions) echo "billing" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  GH_VERSION=0.2.0 run "$UPDATE"
  [ "$status" -eq 0 ]
  [ -s "$GIT_CLONE_LOG" ]
  [ "$(cat "$ORCH_ROOT/.orch-version")" = "0.2.0" ]
}

@test "orch update --force applies despite a live worker" {
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  echo '{"status":"working"}' > "$ORCH_ROOT/_orch/state/workers/w1.json"
  GH_VERSION=0.2.0 run "$UPDATE" --force
  [ "$status" -eq 0 ]
  [ "$(cat "$ORCH_ROOT/.orch-version")" = "0.2.0" ]
}

@test "orch update reports no-op when local version is newer than upstream" {
  echo "9.9.9" > "$ORCH_ROOT/.orch-version"
  GH_VERSION=0.2.0 run "$UPDATE" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* || "$output" == *"newer"* ]]
}

# --- daily background check: throttle -------------------------------------

@test "daily check performs one network call and records it" {
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  [ -s "$GH_LOG" ]
  [ -f "$ORCH_ROOT/_orch/state/update-check.json" ]
  run jq -r '.update_available' "$ORCH_ROOT/_orch/state/update-check.json"
  [ "$output" = "true" ]
}

@test "a second daily check inside the 24h window makes no network call" {
  GH_VERSION=0.2.0 "$UPDATE" --daily-check
  : > "$GH_LOG"
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "daily check re-fetches once the interval has elapsed" {
  GH_VERSION=0.2.0 "$UPDATE" --daily-check
  past="$(($(date +%s) - 100000))"
  jq --argjson t "$past" '.last_checked_epoch = $t' "$ORCH_ROOT/_orch/state/update-check.json" \
    > "$ORCH_ROOT/_orch/state/update-check.json.tmp"
  mv "$ORCH_ROOT/_orch/state/update-check.json.tmp" "$ORCH_ROOT/_orch/state/update-check.json"
  : > "$GH_LOG"
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  [ -s "$GH_LOG" ]
}

@test "daily check is a no-op when update.enabled is false" {
  jq '.update.enabled = false' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "daily check never fails the caller on network failure" {
  GH_FAIL=1 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  run jq -r '.checked_ok' "$ORCH_ROOT/_orch/state/update-check.json"
  [ "$output" = "false" ]
}

@test "daily check never applies the update itself (notify-only)" {
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  [ ! -s "$GIT_CLONE_LOG" ]
  [ "$(cat "$ORCH_ROOT/.orch-version")" = "0.1.0" ]
}

# --- heartbeat wiring -----------------------------------------------------

@test "heartbeat.sh invokes the daily update check" {
  grep -q "update.sh.*--daily-check" "$SRC/_orch/heartbeat.sh"
}

@test "heartbeat.sh's daily-check call is guarded off under bats (BATS_TEST_FILENAME)" {
  # Guards against a real network call sneaking into some OTHER test file that
  # sources/runs heartbeat_main with a config carrying update.enabled=true
  # (e.g. a fixture copied from the real config.json) — see heartbeat.sh.
  grep -q "BATS_TEST_FILENAME" "$SRC/_orch/heartbeat.sh"
}

@test "BATS_TEST_FILENAME reaches heartbeat.sh even launched as its own forked process (nohup, matching bootstrap.sh)" {
  # bootstrap.sh starts heartbeat.sh via `nohup "$here/heartbeat.sh" ... &` —
  # a genuine subprocess exec of a separate script, not a sourced function
  # call within this same bats process. injectfix_heartbeat_safety_valve.bats
  # only calls `heartbeat_main &` after sourcing, which shares this process's
  # environment trivially and would pass even if env inheritance across a real
  # exec boundary were broken. Run the actual heartbeat.sh the way bootstrap.sh
  # does, and prove the guard still sees BATS_TEST_FILENAME there rather than
  # assuming a fork+exec preserves it.
  jq '.intervals.normal_seconds = 1 | .intervals.idle_seconds = 1' \
    "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"

  ( nohup "$SRC/_orch/heartbeat.sh" >"$BATS_TEST_TMPDIR/heartbeat.out" 2>&1 &
    echo $! > "$BATS_TEST_TMPDIR/hb.pid" )
  sleep 2
  hb_pid="$(cat "$BATS_TEST_TMPDIR/hb.pid")"
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true

  [ ! -s "$GH_LOG" ]
  [ ! -f "$ORCH_ROOT/_orch/state/update-check.json" ]
}

# The three tests below strip BATS_TEST_FILENAME (env -u) from the forked
# heartbeat.sh's own environment specifically, so — unlike every other test in
# this file — they exercise the REAL production code path (mtime pre-filter,
# upd_enabled) rather than being trivially satisfied by the bats guard above.
# gh/git/tmux stay stubbed (STUBBIN is still on PATH), so this is still fully
# hermetic; only the one env var is removed for the child process.

@test "heartbeat forks update.sh once the mtime window HAS elapsed (positive control)" {
  jq '.intervals.normal_seconds = 1 | .intervals.idle_seconds = 1' \
    "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"

  ( env -u BATS_TEST_FILENAME nohup "$SRC/_orch/heartbeat.sh" >"$BATS_TEST_TMPDIR/hb-due.out" 2>&1 &
    echo $! > "$BATS_TEST_TMPDIR/hb-due.pid" )
  sleep 2
  hb_pid="$(cat "$BATS_TEST_TMPDIR/hb-due.pid")"
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true

  [ -s "$GH_LOG" ]
}

@test "heartbeat's mtime pre-filter actually SKIPS the fork when NOT due (kills an 'always due' mutant)" {
  # update.sh's OWN --daily-check has its own (necessarily correct, per its
  # own tests) internal throttle too, reading last_checked_epoch from INSIDE
  # the JSON. If this test's state file satisfied BOTH the outer mtime check
  # and that inner field check, an "if true" mutant in heartbeat's pre-filter
  # would still produce an empty GH_LOG — the fork would happen, but
  # update.sh's own internal throttle would then independently no-op it,
  # making the mutant invisible to a bare "GH_LOG is empty" assertion.
  # Deliberately decouple the two signals: the FILE's mtime is fresh (jq -n
  # writing it just now), satisfying the outer `find -mmin` check ("not
  # due" — heartbeat should never fork at all) — but the last_checked_epoch
  # VALUE inside that JSON is 0, so if the mutant forks anyway, update.sh's
  # own inner throttle sees "due" and DOES call gh, giving the mutant
  # somewhere to be caught.
  jq '.intervals.normal_seconds = 1 | .intervals.idle_seconds = 1' \
    "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  mkdir -p "$ORCH_ROOT/_orch/state"
  jq -n '{last_checked_epoch: 0, update_available: false}' \
    > "$ORCH_ROOT/_orch/state/update-check.json"

  ( env -u BATS_TEST_FILENAME nohup "$SRC/_orch/heartbeat.sh" >"$BATS_TEST_TMPDIR/hb-notdue.out" 2>&1 &
    echo $! > "$BATS_TEST_TMPDIR/hb-notdue.pid" )
  sleep 2
  hb_pid="$(cat "$BATS_TEST_TMPDIR/hb-notdue.pid")"
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true

  [ ! -s "$GH_LOG" ]
}

@test "heartbeat never forks update.sh when update.enabled is false (kills an 'always enabled' mutant)" {
  # GH_LOG alone can't kill this mutant: update.sh's OWN daily_check() reads
  # config.json fresh and independently sees enabled=false too, so even a
  # heartbeat that WRONGLY forks it produces an empty GH_LOG (update.sh
  # no-ops before ever reaching gh) — indistinguishable from the outer gate
  # correctly never forking at all. But update.sh's daily_check() logs
  # "daily check disabled by config" to orch.log whenever IT makes that
  # decision — so that line's ABSENCE is the actual proof the outer gate
  # itself never forked, which is what this test needs to show.
  jq '.intervals.normal_seconds = 1 | .intervals.idle_seconds = 1 | .update.enabled = false' \
    "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"

  ( env -u BATS_TEST_FILENAME nohup "$SRC/_orch/heartbeat.sh" >"$BATS_TEST_TMPDIR/hb-disabled.out" 2>&1 &
    echo $! > "$BATS_TEST_TMPDIR/hb-disabled.pid" )
  sleep 2
  hb_pid="$(cat "$BATS_TEST_TMPDIR/hb-disabled.pid")"
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true

  [ ! -s "$GH_LOG" ]
  ! grep -q "daily check disabled by config" "$ORCH_ROOT/_orch/state/orch.log" 2>/dev/null
}

@test "daily check fails closed (disabled, logged) when config.json cannot be parsed at all" {
  echo '{ this is not valid json' > "$ORCH_ROOT/_orch/config.json"
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

# --- reviewer findings (rv91 on PR #95) --------------------------------------

@test "a non-integer update.interval_hours does not crash --daily-check (falls back to 24h)" {
  jq '.update.interval_hours = 0.5' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  # Must still reach _write_state (not die on the bad arithmetic) — otherwise
  # heartbeat's mtime pre-filter never sees a "checked" file and re-forks/
  # re-fetches every single tick instead of throttling.
  [ -f "$ORCH_ROOT/_orch/state/update-check.json" ]
}

@test "a non-numeric-string update.interval_hours does not crash --daily-check (falls back to 24h)" {
  jq '.update.interval_hours = "often"' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  [ -f "$ORCH_ROOT/_orch/state/update-check.json" ]
}

@test "a JSON/HTML body masquerading as VERSION (e.g. gh ignoring the raw Accept header) is never trusted as a version" {
  cat > "$STUBBIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
if [ "\$1" = "api" ]; then
  printf '%s' '{"name":"VERSION","content":"MC4yLjAK"}'
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBBIN/gh"
  run "$UPDATE" --check
  [ "$status" -ne 0 ]
  [[ "$output" != *'"name":"VERSION"'* ]]
}

@test "an unwritable state dir does not cause --daily-check to re-fetch every invocation" {
  # lib.sh's own `mkdir -p "$WORKERS_DIR"` at source time requires the state
  # dir to be writable on a FRESH create — that's a toolkit-wide invariant,
  # not something update.sh controls — so pre-create workers/ while writable,
  # THEN lock the state dir down: `mkdir -p` on an already-existing dir needs
  # no write permission, so lib.sh still sources fine, but _write_state's own
  # new file (update-check.json.tmp.$$) can no longer be created — the
  # narrower, realistic failure this guards.
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  touch "$ORCH_ROOT/_orch/state/orch.log"   # lib.sh's log() appends to an existing
                                             # file, which needs no dir write access —
                                             # pre-create it so THIS test isolates
                                             # _write_state's own failure, not log()'s
  chmod 555 "$ORCH_ROOT/_orch/state"
  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  chmod 755 "$ORCH_ROOT/_orch/state"
  [ "$status" -eq 0 ]
}

@test "on a write failure, _write_state still touches the state path so the mtime throttle doesn't retry-storm" {
  # The "unwritable state dir" test above can't prove this line does
  # anything: with the DIRECTORY itself unwritable, the fallback touch
  # (`: > "$UPDATE_STATE"`) fails right alongside the primary jq+mv write, so
  # deleting the fallback wouldn't change that test's observable outcome
  # (no file either way). Distinguish them here: fail only the jq write
  # itself (directory stays fully writable), so a correct fallback touch
  # SHOULD still succeed and create the path — proving the touch line is
  # actually doing something, not just dead code alongside a redundant
  # directory-level failure.
  REALJQ="$(command -v jq)"
  cat > "$STUBBIN/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-n" ]; then
    exit 1
  fi
done
exec "$REALJQ" "\$@"
EOF
  chmod +x "$STUBBIN/jq"

  GH_VERSION=0.2.0 run "$UPDATE" --daily-check
  [ "$status" -eq 0 ]
  [ -f "$ORCH_ROOT/_orch/state/update-check.json" ]
}

@test "an install with no version stamp at all (unknown) can still see an update as available" {
  rm -f "$ORCH_ROOT/.orch-version" "$ORCH_ROOT/VERSION"
  GH_VERSION=0.2.0 run "$UPDATE" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"update available"* ]]
  [[ "$output" != *"nothing to do"* ]]
}

# --- orch dispatch ----------------------------------------------------------

@test "orch help documents the update command" {
  run "$SRC/orch" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"orch update"* ]]
}
