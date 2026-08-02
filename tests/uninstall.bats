#!/usr/bin/env bats
# Hermetic tests for uninstall.sh: removes exactly what install.sh added, is
# idempotent, and leaves settings.local.json / the target's own files alone.
# Operates entirely against a throwaway target dir under BATS_TEST_TMPDIR.

INSTALL="$BATS_TEST_DIRNAME/../install.sh"
UNINSTALL="$BATS_TEST_DIRNAME/../uninstall.sh"

setup() {
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"
}

@test "uninstall.sh removes everything install.sh added" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]

  run "$UNINSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [ ! -d "$TARGET/_orch" ]
  [ ! -d "$TARGET/tmux" ]
  [ ! -f "$TARGET/orch" ]
  [ ! -f "$TARGET/.orch-version" ]
}

@test "uninstall.sh is idempotent (safe to run twice, or on a never-installed target)" {
  run "$UNINSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to uninstall"* ]]

  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  run "$UNINSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  run "$UNINSTALL" "$TARGET"
  [ "$status" -eq 0 ]
}

@test "uninstall.sh leaves settings.local.json in place" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  run "$UNINSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.claude/settings.local.json" ]
}

@test "uninstall.sh trims only the toolkit's own gitignore lines" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  echo "my-own-ignore/" >> "$TARGET/.gitignore"

  run "$UNINSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  run cat "$TARGET/.gitignore"
  [[ "$output" == *"my-own-ignore/"* ]]
  [[ "$output" != *"_orch/state/"* ]]
}

@test "uninstall.sh never touches a git worktree under ../wt" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  mkdir -p "$TARGET/../wt/w1"
  echo marker > "$TARGET/../wt/w1/keep.txt"

  run "$UNINSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/../wt/w1/keep.txt" ]
}

@test "uninstall.sh defaults the target to the current directory" {
  "$INSTALL" "$TARGET" >/dev/null
  cd "$TARGET"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -d "$TARGET/_orch" ]
}
