#!/usr/bin/env bats
# Hermetic tests for issue #92: `orch up --name <name>` names a session and
# persists that name per install, so every later `orch` invocation (in a
# clean environment, no SESSION_NAME set) resolves to the same session.
#
# Precedence: --name flag > SESSION_NAME env > persisted name > orch-<hash> default.
#
# bootstrap.sh/lib.sh resolve their own dir from $BASH_SOURCE, so each test
# runs from a throwaway toolkit copy with heartbeat.sh/watchdog.sh stubbed to
# no-ops — this must never launch the real background loops or touch a real
# tmux session.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  SESSIONS_FILE="$BATS_TEST_TMPDIR/tmux-sessions"
  OPTS_DIR="$BATS_TEST_TMPDIR/tmux-opts"
  : > "$SESSIONS_FILE"
  mkdir -p "$OPTS_DIR"
}

teardown() {
  [ -n "${BG_PID:-}" ] && kill "$BG_PID" 2>/dev/null || true
  [ -n "${BG_PID2:-}" ] && kill "$BG_PID2" 2>/dev/null || true
}

# A STATEFUL tmux stub: tracks which session names "exist" (list-sessions) and
# session-scoped @-options (set-option/show-options), backed by plain files
# under $BATS_TEST_TMPDIR so state survives across separate invocations within
# one test (bootstrap.sh runs as a real subprocess, not sourced). This is what
# lets tests seed "a session already exists" / "@orch_owner is already set" by
# calling the SAME stub commands production code calls, instead of hand-writing
# to a file production code doesn't read (see issue #92 rv92 finding 2: a
# fabricated state no real run could produce doesn't prove the guard works).
stub_tmux() {
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$BATS_TEST_TMPDIR/tmux.log"
SESSIONS_FILE="$SESSIONS_FILE"
OPTS_DIR="$OPTS_DIR"
case "\${1:-}" in
  has-session)
    # Real tmux matches an unambiguous PREFIX too (confirmed against tmux
    # 3.4), not just an exact name -- fake that here so a regression back to
    # `tmux has-session -t <name>` (instead of session_exists()'s exact
    # list-sessions match) is actually caught by the hijack test below,
    # instead of this stub silently being stricter than real tmux.
    grep -qxF -- "\${3:-}" "\$SESSIONS_FILE" 2>/dev/null && exit 0
    grep -q  -- "^\${3:-}" "\$SESSIONS_FILE" 2>/dev/null && exit 0
    exit 1
    ;;
  list-sessions)
    cat "\$SESSIONS_FILE"
    exit 0
    ;;
  new-session)
    name="" prev=""
    for a in "\$@"; do
      [ "\$prev" = "-s" ] && name="\$a"
      prev="\$a"
    done
    [ -n "\$name" ] && echo "\$name" >> "\$SESSIONS_FILE"
    exit 0
    ;;
  set-option)
    shift
    tgt=""
    if [ "\${1:-}" = "-t" ]; then tgt="\$2"; shift 2; fi
    key="\${1:-}"; shift || true
    val="\$*"
    if [ -n "\$tgt" ] && [ -n "\$key" ]; then
      printf '%s' "\$val" > "\$OPTS_DIR/\$tgt \$key"
    fi
    exit 0
    ;;
  show-options)
    shift
    tgt=""
    if [ "\${1:-}" = "-t" ]; then tgt="\$2"; shift 2; fi
    [ "\${1:-}" = "-v" ] && shift
    key="\${1:-}"
    f="\$OPTS_DIR/\$tgt \$key"
    if [ -f "\$f" ]; then cat "\$f"; exit 0; fi
    exit 1
    ;;
  capture-pane) echo '> ready for shortcuts' ;;
  show-buffer)  exit 1 ;;
esac
exit 0
EOF
  cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"
}

# Seed "a session named <1> already exists" the same way a real bootstrap.sh
# create-path would have recorded it -- via the stub's own new-session case.
seed_session() { "$STUBBIN/tmux" new-session -d -s "$1" -n orchestrator -c /tmp >/dev/null; } # <name>
# Seed "session <1> is owned by toolkit root <2>" the same way a real
# bootstrap.sh create-path would have recorded it -- via set-option.
seed_owner() { "$STUBBIN/tmux" set-option -t "$1" @orch_owner "$2" >/dev/null; } # <session> <owner>

wait_for() { # <predicate...>, poll up to 2s * ORCH_TEST_TIMEOUT_SCALE (default 1x) so a loaded box gets slack instead of a flake
  local scale="${ORCH_TEST_TIMEOUT_SCALE:-1}"
  [ "$scale" -ge 1 ] 2>/dev/null || scale=1
  for _ in $(seq 1 $((100 * scale))); do "$@" && return 0; sleep 0.02; done
  return 1
}

make_toolkit() { # <dir> -> sets up a throwaway toolkit copy at <dir>/_orch
  local dir="$1"
  mkdir -p "$dir/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh" "$dir/_orch/bootstrap.sh"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$dir/_orch/lib.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/_orch/heartbeat.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/_orch/watchdog.sh"
  chmod +x "$dir/_orch/bootstrap.sh" "$dir/_orch/heartbeat.sh" "$dir/_orch/watchdog.sh"
  jq -n '{watchdog:{enabled:false}}' > "$dir/_orch/config.json"
}

# --- lib.sh precedence -------------------------------------------------------

@test "lib.sh: persisted name beats the hash default" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state"
  printf 'billing\n' > "$ROOT/_orch/state/session-name"
  ( unset SESSION_NAME
    export ORCH_ROOT="$ROOT"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    [ "$SESSION_NAME" = "billing" ]
  )
}

@test "lib.sh: SESSION_NAME env beats the persisted name" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state"
  printf 'billing\n' > "$ROOT/_orch/state/session-name"
  ( export ORCH_ROOT="$ROOT" SESSION_NAME="env-override"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    [ "$SESSION_NAME" = "env-override" ]
  )
}

@test "lib.sh: no persisted name and no env falls back to the hash default" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state"
  ( unset SESSION_NAME
    export ORCH_ROOT="$ROOT"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    [[ "$SESSION_NAME" =~ ^orch-[0-9a-f]{8}$ ]]
  )
}

@test "lib.sh: an empty persisted-name file is treated as absent (hash default)" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state"
  printf '' > "$ROOT/_orch/state/session-name"
  ( unset SESSION_NAME
    export ORCH_ROOT="$ROOT"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    [[ "$SESSION_NAME" =~ ^orch-[0-9a-f]{8}$ ]]
  )
}

@test "lib.sh: _orch_persisted_session_name fails (nonzero) and prints nothing for an empty file" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state"
  printf '' > "$ROOT/_orch/state/session-name"
  ( export ORCH_ROOT="$ROOT"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    if out="$(_orch_persisted_session_name)"; then rc=0; else rc=$?; fi
    [ -z "$out" ] && [ "$rc" -ne 0 ]
  )
}

@test "lib.sh: _orch_persisted_session_name succeeds and prints the name for a real persisted file" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state"
  printf 'billing\n' > "$ROOT/_orch/state/session-name"
  ( export ORCH_ROOT="$ROOT"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    if out="$(_orch_persisted_session_name)"; then rc=0; else rc=$?; fi
    [ "$out" = "billing" ] && [ "$rc" -eq 0 ]
  )
}

@test "lib.sh: valid_session_name accepts letters/digits/_/- and rejects : and ." {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  ( export ORCH_ROOT="$ROOT"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    valid_session_name "billing-2" || exit 1
    valid_session_name "billing:2" && exit 1
    valid_session_name "billing.2" && exit 1
    valid_session_name "" && exit 1
    exit 0
  )
}

# --- rv92 NON-BLOCKING 5: validation must apply to the RESOLVED name, not
# just a fresh --name value -- a bad SESSION_NAME env or a hand-edited
# persisted-name file was previously accepted unvalidated and would silently
# target the wrong tmux pane everywhere it's interpolated.

@test "lib.sh: an invalid SESSION_NAME env does NOT exit lib.sh itself (help/down must survive)" {
  # rv92 finding 2: lib.sh is sourced unconditionally by every entrypoint,
  # including ones that need no valid session name (orch help, orch down).
  # A hard exit at source time took those out too, with the only recovery
  # being to hand-edit state on disk. Sourcing must always succeed; the
  # entrypoints that actually need a valid name call require_valid_session_name.
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  run bash -c '
    export ORCH_ROOT="'"$ROOT"'" SESSION_NAME="bad:name"
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    echo "sourced ok, error=[$SESSION_NAME_ERROR]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced ok"* ]]
  [[ "$output" == *"error=["*"invalid"* ]]
}

@test "lib.sh: require_valid_session_name fails loudly for an invalid SESSION_NAME env" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  run bash -c '
    export ORCH_ROOT="'"$ROOT"'" SESSION_NAME="bad:name"
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    require_valid_session_name
    echo "should not reach here"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]]
  [[ "$output" != *"should not reach here"* ]]
}

@test "lib.sh: require_valid_session_name fails loudly for a hand-edited invalid persisted-name file" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state"
  printf 'bad:name\n' > "$ROOT/_orch/state/session-name"
  run bash -c '
    unset SESSION_NAME
    export ORCH_ROOT="'"$ROOT"'"
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    require_valid_session_name
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]]
}

@test "lib.sh: require_valid_session_name is a no-op for a valid SESSION_NAME" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  run bash -c '
    export ORCH_ROOT="'"$ROOT"'" SESSION_NAME="good-name"
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    require_valid_session_name
    echo "reached"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"reached"* ]]
}

# --- bootstrap.sh: --name flag -----------------------------------------------

@test "bootstrap.sh: --name beats SESSION_NAME env and persists to state/session-name" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux   # no sessions exist yet -> create path

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="env-name"
  mkdir -p "$PROJECT_ROOT"

  run "$ROOT/_orch/bootstrap.sh" --name flag-name
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag-name"* ]]
  [ "$(cat "$ROOT/_orch/state/session-name")" = "flag-name" ]
  grep -qE '(^|[[:space:]])-s flag-name([[:space:]]|$)' "$BATS_TEST_TMPDIR/tmux.log"
}

@test "bootstrap.sh: --name persists so a later clean-environment invocation resolves to it" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  ( export ORCH_ROOT="$ROOT" PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$PROJECT_ROOT"
    unset SESSION_NAME
    "$ROOT/_orch/bootstrap.sh" --name my-session >/dev/null
  )

  # Simulate a completely separate, later invocation: clean environment, no
  # --name, no SESSION_NAME. This is the whole point of the issue.
  resolved="$(unset SESSION_NAME; ORCH_ROOT="$ROOT" bash -c '
    source "'"$ROOT"'/_orch/lib.sh"; printf %s "$SESSION_NAME"')"
  [ "$resolved" = "my-session" ]
}

@test "bootstrap.sh: an invalid --name is rejected loudly and nothing is persisted" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"
  unset SESSION_NAME

  run "$ROOT/_orch/bootstrap.sh" --name "bad:name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]] || [[ "$output" == *"--name"* ]]
  [ ! -f "$ROOT/_orch/state/session-name" ]
  # Must not have attempted to create a tmux session with the bad name.
  [ ! -f "$BATS_TEST_TMPDIR/tmux.log" ] || ! grep -q "bad:name" "$BATS_TEST_TMPDIR/tmux.log"
}

@test "bootstrap.sh: --name with a '.' is also rejected" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"
  unset SESSION_NAME

  run "$ROOT/_orch/bootstrap.sh" --name "bad.name"
  [ "$status" -ne 0 ]
  [ ! -f "$ROOT/_orch/state/session-name" ]
}

@test "bootstrap.sh: renaming via --name while the OLD persisted session is still alive refuses" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  mkdir -p "$ROOT/_orch/state"
  printf 'old-name\n' > "$ROOT/_orch/state/session-name"
  stub_tmux
  seed_session old-name   # the persisted session is genuinely alive

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"
  unset SESSION_NAME

  run "$ROOT/_orch/bootstrap.sh" --name new-name
  [ "$status" -ne 0 ]
  [[ "$output" == *"old-name"* ]]
  [ "$(cat "$ROOT/_orch/state/session-name")" = "old-name" ]
}

@test "bootstrap.sh: --name re-affirming the SAME already-persisted name is a no-op rename (allowed)" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  mkdir -p "$ROOT/_orch/state"
  printf 'same-name\n' > "$ROOT/_orch/state/session-name"
  stub_tmux
  seed_session same-name   # already exists -> reuse path

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"
  unset SESSION_NAME

  run "$ROOT/_orch/bootstrap.sh" --name same-name
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/_orch/state/session-name")" = "same-name" ]
}

# --- rv92 BLOCKING 1: --name must never hijack a session it doesn't exactly name ---
# tmux target resolution matches an unambiguous PREFIX (confirmed against real
# tmux 3.4: `has-session -t bill` succeeds against a live "billing" session).
# A plain has-session/`-t` reuse check is therefore exploitable: `--name bill`
# against a live "billing" would silently adopt it, rehydrate-inject into ITS
# master pane, and every later send/tail/down would drive someone else's
# session. bootstrap.sh must resolve existence via an EXACT list-sessions match.
@test "bootstrap.sh: --name that is a prefix of a DIFFERENT live session does not hijack it" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux
  seed_session billing
  seed_owner billing /some/other/toolkit/root

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"
  unset SESSION_NAME

  run "$ROOT/_orch/bootstrap.sh" --name bill
  [ "$status" -eq 0 ]
  # Must be treated as a brand-new, DISTINCT session -- not a reuse of "billing".
  [[ "$output" != *"billing"* ]]
  [[ "$output" == *"'bill'"* ]] || [[ "$output" == *" bill"* ]]
  grep -qE '(^|[[:space:]])-s bill([[:space:]]|$)' "$BATS_TEST_TMPDIR/tmux.log"
  [ "$(cat "$ROOT/_orch/state/session-name")" = "bill" ]
  # "billing"'s ownership record must be completely untouched.
  [ "$("$STUBBIN/tmux" show-options -t billing -v @orch_owner)" = "/some/other/toolkit/root" ]
}

# --- rv92 BLOCKING 2: the collision guard must fire on state a real run produces ---
# Ownership now lives ON the tmux session (a session-scoped @orch_owner
# option), set by the REAL bootstrap.sh create path -- not hand-seeded into a
# file production code no longer reads. Root A creates the session for real;
# root B then adopts the SAME name for real, exercising the actual guard.
@test "bootstrap.sh: reusing a session a DIFFERENT root created (for real) warns loudly and mentions --name" {
  ROOT_A="$BATS_TEST_TMPDIR/toolkit_a"
  ROOT_B="$BATS_TEST_TMPDIR/toolkit_b"
  make_toolkit "$ROOT_A"
  make_toolkit "$ROOT_B"
  stub_tmux

  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch-shared-test"
  mkdir -p "$PROJECT_ROOT"

  ORCH_ROOT="$ROOT_A" "$ROOT_A/_orch/bootstrap.sh" >/dev/null   # real create path

  export ORCH_ROOT="$ROOT_B"
  run "$ROOT_B/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"$ROOT_A"* ]]
  [[ "$output" == *"--name"* ]]
}

@test "bootstrap.sh: reusing a session THIS root created (for real) stays a quiet reassurance" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch-solo-test"
  mkdir -p "$PROJECT_ROOT"

  "$ROOT/_orch/bootstrap.sh" >/dev/null   # real create path

  run "$ROOT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists; reusing"* ]]
  [[ "$output" != *"WARNING"* ]]
}

# --- rv92 BLOCKING 3: the rename guard must see the RESOLVED old name, not just
# the persisted file (empty on the very first --name, and blind to SESSION_NAME) ---

@test "bootstrap.sh: the FIRST-EVER --name still refuses if the current hash-default session is alive" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"
  unset SESSION_NAME

  hash_name="$(ORCH_ROOT="$ROOT" bash -c '
    source "'"$ROOT"'/_orch/lib.sh"; printf %s "$SESSION_NAME"')"
  seed_session "$hash_name"   # the live session under the pre-#92 default name

  # No persisted file exists at all yet -- this is the FIRST --name ever run.
  [ ! -f "$ROOT/_orch/state/session-name" ]

  run "$ROOT/_orch/bootstrap.sh" --name billing
  [ "$status" -ne 0 ]
  [[ "$output" == *"$hash_name"* ]]
  [ ! -f "$ROOT/_orch/state/session-name" ]
}

@test "bootstrap.sh: --name refuses when the session currently pinned via SESSION_NAME env is alive" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux
  seed_session envpin

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="envpin"
  mkdir -p "$PROJECT_ROOT"

  run "$ROOT/_orch/bootstrap.sh" --name billing
  [ "$status" -ne 0 ]
  [[ "$output" == *"envpin"* ]]
  [ ! -f "$ROOT/_orch/state/session-name" ]
}

@test "bootstrap.sh: a successful rename stops the stale heartbeat/watchdog so they relaunch under the new name" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT" "$ROOT/_orch/state"
  unset SESSION_NAME

  # Both loops resolve SESSION_NAME once, at their OWN process startup, by
  # sourcing lib.sh -- an already-running loop never notices a rename on its
  # own. Simulate exactly that: real, still-alive heartbeat/watchdog
  # processes (matching pid_is_expected's argv check) with pidfiles recorded
  # the way a real prior `orch up` would leave them, e.g. after the operator
  # killed the old tmux session directly instead of via `orch down`.
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$ROOT/_orch/heartbeat.sh"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$ROOT/_orch/watchdog.sh"
  chmod +x "$ROOT/_orch/heartbeat.sh" "$ROOT/_orch/watchdog.sh"
  "$ROOT/_orch/heartbeat.sh" & BG_PID=$!
  "$ROOT/_orch/watchdog.sh"  & BG_PID2=$!
  echo "$BG_PID"  > "$ROOT/_orch/state/heartbeat.pid"
  echo "$BG_PID2" > "$ROOT/_orch/state/watchdog.pid"
  wait_for kill -0 "$BG_PID"
  wait_for kill -0 "$BG_PID2"

  run "$ROOT/_orch/bootstrap.sh" --name renamed
  [ "$status" -eq 0 ]

  wait_for bash -c "! kill -0 $BG_PID 2>/dev/null"
  run kill -0 "$BG_PID"
  [ "$status" -ne 0 ]
  run kill -0 "$BG_PID2"
  [ "$status" -ne 0 ]

  new_hb_pid="$(cat "$ROOT/_orch/state/heartbeat.pid")"
  [ "$new_hb_pid" != "$BG_PID" ]
  kill -0 "$new_hb_pid"
  kill "$new_hb_pid" 2>/dev/null || true
}

@test "bootstrap.sh: a valid --name wins even over an invalid pre-existing SESSION_NAME env (rv92 finding 3)" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="bad:name"
  mkdir -p "$PROJECT_ROOT"

  run "$ROOT/_orch/bootstrap.sh" --name good
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/_orch/state/session-name")" = "good" ]
  grep -qE '(^|[[:space:]])-s good([[:space:]]|$)' "$BATS_TEST_TMPDIR/tmux.log"
}

# --- rv92 BLOCKING 2 (finding 2): commands needing no valid session name must
# survive a corrupt persisted-name file, not just print a recovery hint ------

make_full_toolkit() { # <dir> -> a throwaway copy of orch + lib.sh + stop.sh
  local dir="$1"
  mkdir -p "$dir/_orch/state"
  cp "$BATS_TEST_DIRNAME/../orch" "$dir/orch"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$dir/_orch/lib.sh"
  cp "$BATS_TEST_DIRNAME/../_orch/stop.sh" "$dir/_orch/stop.sh"
  chmod +x "$dir/orch" "$dir/_orch/stop.sh"
  jq -n '{}' > "$dir/_orch/config.json"
}

@test "orch help survives a corrupt persisted session-name file" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_full_toolkit "$ROOT"
  printf 'bad:name\n' > "$ROOT/_orch/state/session-name"

  # issue #105: this ROOT is a throwaway, non-git toolkit copy under bats'
  # own tmp dir -- unrelated to whatever ORCH_ROOT the invoking shell may
  # ambiently carry (this repo's own dev/worker shells routinely export one),
  # so the mismatch guard can't establish it's the same install via git
  # identity. Isolate explicitly, same idiom every other test in this file
  # already relies on.
  run env -u ORCH_ROOT "$ROOT/orch" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux + Claude Code orchestrator"* ]]
}

@test "orch down survives a corrupt persisted session-name file" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_full_toolkit "$ROOT"
  printf 'bad:name\n' > "$ROOT/_orch/state/session-name"

  # issue #105: see the isolation note in the previous test.
  run env -u ORCH_ROOT "$ROOT/orch" down
  [ "$status" -eq 0 ]
}

# --- orch help ----------------------------------------------------------------

@test "orch help: documents --name and the full precedence order (in order: flag > env > persisted > default)" {
  run "$BATS_TEST_DIRNAME/../orch" help
  [ "$status" -eq 0 ]
  # Ordering, not just presence: a mutation that drops or reshuffles the
  # precedence sentence must fail this, not just "mentions --name somewhere".
  [[ "$output" == *"--name flag"*"SESSION_NAME env"*"persisted name"*"orch-<hash"* ]]
}

# --- wait_for() deadline (issue #125: de-flake under load) --------------------

@test "wait_for's deadline scales with ORCH_TEST_TIMEOUT_SCALE instead of a fixed 100-iteration ceiling" {
  # A predicate that only turns true on its 150th call -- past the unscaled
  # 100-iteration ceiling but within a 2x-scaled 200-iteration one. Counts
  # calls rather than wall-clock time so the assertion is deterministic
  # (fork/sleep overhead alone can pad a timing-based check past its bound).
  CALLS_FILE="$BATS_TEST_TMPDIR/wait_for_calls"
  : > "$CALLS_FILE"
  ready_on_150th_call() {
    printf 'x' >> "$CALLS_FILE"
    [ "$(wc -c < "$CALLS_FILE")" -ge 150 ]
  }
  ORCH_TEST_TIMEOUT_SCALE=2 wait_for ready_on_150th_call
}
