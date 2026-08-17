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

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
}

stub_tmux() { # <has_session_exit_code>
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$BATS_TEST_TMPDIR/tmux.log"
case "\${1:-}" in
  has-session)  exit $1 ;;
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

@test "bootstrap.sh: reusing a session THIS root created stays a quiet reassurance" {
  ROOT="$BATS_TEST_TMPDIR/toolkit"
  make_toolkit "$ROOT"
  stub_tmux 0   # has-session succeeds -> reuse path
  mkdir -p "$ROOT/_orch/state"
  printf '%s\n' "$ROOT" > "$ROOT/_orch/state/session-owner"

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch-shared-test"
  mkdir -p "$PROJECT_ROOT"

  run "$ROOT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists; reusing"* ]]
  [[ "$output" != *"WARNING"* ]]
}

@test "bootstrap.sh: reusing a session a DIFFERENT root created warns loudly, naming both roots" {
  ROOT_A="$BATS_TEST_TMPDIR/toolkit_a"
  ROOT_B="$BATS_TEST_TMPDIR/toolkit_b"
  make_toolkit "$ROOT_A"
  make_toolkit "$ROOT_B"
  stub_tmux 0   # has-session succeeds -> reuse path
  mkdir -p "$ROOT_B/_orch/state"
  # Simulate: root A created the session first.
  printf '%s\n' "$ROOT_A" > "$ROOT_B/_orch/state/session-owner"

  export ORCH_ROOT="$ROOT_B"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch-shared-test"
  mkdir -p "$PROJECT_ROOT"

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
  stub_tmux 1   # has-session fails -> create path

  export ORCH_ROOT="$ROOT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch-fresh-test"
  mkdir -p "$PROJECT_ROOT"

  run "$ROOT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/_orch/state/session-owner")" = "$ROOT" ]
}
