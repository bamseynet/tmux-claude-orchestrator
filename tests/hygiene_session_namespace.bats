#!/usr/bin/env bats
# Hermetic tests for issue #81: the tmux session name is namespaced per toolkit
# root by default, so two installs in different directories never collide on the
# bare literal "orch" — and if they somehow still share a session name (e.g. an
# explicit SESSION_NAME override on both), bootstrap.sh warns loudly instead of
# printing an unconditional "reusing" reassurance.
#
# bootstrap.sh resolves its own dir from $BASH_SOURCE, so each test runs it from
# a throwaway toolkit copy with heartbeat.sh/watchdog.sh stubbed to no-ops —
# this must never launch the real background loops or touch a real tmux session.
#
# Ownership tracking was hardened by issue #92 (rv92 finding 2): it used to live
# in a file under THIS install's own $STATE_DIR, which a DIFFERENT install could
# never actually populate on a real run (two ORCH_ROOTs have two separate state
# dirs) — so the guard could only be exercised by hand-seeding a file production
# code never writes there. It now lives ON the tmux session itself (a
# session-scoped @orch_owner option), which every install resolving the same
# session name can see for real. These tests exercise that for real: root A's
# bootstrap.sh actually creates the session, root B's actually adopts it.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  SESSIONS_FILE="$BATS_TEST_TMPDIR/tmux-sessions"
  OPTS_DIR="$BATS_TEST_TMPDIR/tmux-opts"
  : > "$SESSIONS_FILE"
  mkdir -p "$OPTS_DIR"
}

# A STATEFUL tmux stub (list-sessions/new-session/set-option/show-options
# backed by plain files under $BATS_TEST_TMPDIR), so two separate bootstrap.sh
# invocations in one test see the same fake "tmux server" — same as two real
# installs on one machine sharing one real tmux server.
stub_tmux() {
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$BATS_TEST_TMPDIR/tmux.log"
SESSIONS_FILE="$SESSIONS_FILE"
OPTS_DIR="$OPTS_DIR"
case "\${1:-}" in
  has-session)
    # Real tmux matches an unambiguous PREFIX too (confirmed against tmux
    # 3.4) -- fake that here so this stub is never stricter than real tmux
    # (see issue #92 rv92 finding 1, fixed in bootstrap.sh via an exact
    # list-sessions match instead of a bare has-session check).
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

# --- default derivation ----------------------------------------------------

@test "lib.sh: default SESSION_NAME is namespaced (not the bare literal 'orch')" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  ( unset SESSION_NAME
    export ORCH_ROOT="$ROOT"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    [[ "$SESSION_NAME" =~ ^orch-[0-9a-f]{8}$ ]]
  )
}

@test "lib.sh: two different toolkit roots derive two different session names" {
  ROOT_A="$BATS_TEST_TMPDIR/root_a"
  ROOT_B="$BATS_TEST_TMPDIR/root_b"
  mkdir -p "$ROOT_A/_orch" "$ROOT_B/_orch"

  name_a="$(unset SESSION_NAME; ORCH_ROOT="$ROOT_A" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; printf %s "$SESSION_NAME"')"
  name_b="$(unset SESSION_NAME; ORCH_ROOT="$ROOT_B" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; printf %s "$SESSION_NAME"')"

  [ -n "$name_a" ]
  [ -n "$name_b" ]
  [ "$name_a" != "$name_b" ]
}

@test "lib.sh: the same toolkit root derives the same session name every time" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  name1="$(unset SESSION_NAME; ORCH_ROOT="$ROOT" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; printf %s "$SESSION_NAME"')"
  name2="$(unset SESSION_NAME; ORCH_ROOT="$ROOT" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; printf %s "$SESSION_NAME"')"
  [ "$name1" = "$name2" ]
}

@test "lib.sh: an explicit SESSION_NAME override always wins over the derived default" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  ( export ORCH_ROOT="$ROOT" SESSION_NAME="my-pinned-name"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
    [ "$SESSION_NAME" = "my-pinned-name" ]
  )
}

# --- bootstrap.sh: the regression test that matters most -------------------

@test "bootstrap.sh: reusing a session THIS root created (for real) stays a quiet reassurance" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch-shared-test"
  mkdir -p "$PROJECT_ROOT"

  "$ROOT/_orch/bootstrap.sh" >/dev/null   # real create path, records @orch_owner=$ROOT

  run "$ROOT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists; reusing"* ]]
  [[ "$output" != *"WARNING"* ]]
}

@test "bootstrap.sh: reusing a session a DIFFERENT root created (for real) warns loudly, naming both roots" {
  ROOT_A="$BATS_TEST_TMPDIR/toolkit_a"
  ROOT_B="$BATS_TEST_TMPDIR/toolkit_b"
  make_toolkit "$ROOT_A"
  make_toolkit "$ROOT_B"
  stub_tmux

  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch-shared-test"
  mkdir -p "$PROJECT_ROOT"

  ORCH_ROOT="$ROOT_A" "$ROOT_A/_orch/bootstrap.sh" >/dev/null   # root A creates it for real

  export ORCH_ROOT="$ROOT_B"
  run "$ROOT_B/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"$ROOT_A"* ]]
  [[ "$output" == *"$ROOT_B"* ]]
  [[ "$output" != *"already exists; reusing"* ]]
}

@test "bootstrap.sh: a freshly created session records its owning root" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch-fresh-test"
  mkdir -p "$PROJECT_ROOT"

  run "$ROOT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [ "$("$STUBBIN/tmux" show-options -t "$SESSION_NAME" -v @orch_owner)" = "$ROOT" ]
}
