#!/usr/bin/env bats
# Hermetic tests for install.sh: a fresh install, an idempotent re-install that
# preserves the target's tuned config.json, and the VERSION/.orch-version wiring.
# Operates entirely against a throwaway target dir under BATS_TEST_TMPDIR; never
# touches the real repo tree. No tmux window and no `claude` process is launched
# (install.sh only copies files and writes JSON).

INSTALL="$BATS_TEST_DIRNAME/../install.sh"
SRC="$BATS_TEST_DIRNAME/.."

setup() {
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"   # looks like a git repo root
}

@test "install.sh copies the toolkit and writes .orch-version matching VERSION" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [ -d "$TARGET/_orch" ]
  [ -d "$TARGET/tmux" ]
  [ -x "$TARGET/orch" ]
  [ -f "$TARGET/.orch-version" ]
  [ "$(cat "$TARGET/.orch-version")" = "$(cat "$SRC/VERSION")" ]
}

@test "install.sh never copies runtime state" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [ ! -d "$TARGET/_orch/state" ]
}

@test "install.sh writes settings.local.json with teams + permission allowlist when absent" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  settings="$TARGET/.claude/settings.local.json"
  [ -f "$settings" ]
  run jq -r '.teammateMode' "$settings"
  [ "$output" = "tmux" ]
  run jq -r '.permissions.allow[0]' "$settings"
  [ "$output" = "Bash(tmux:*)" ]
}

@test "install.sh leaves an existing settings.local.json untouched" {
  mkdir -p "$TARGET/.claude"
  echo '{"custom":"value"}' > "$TARGET/.claude/settings.local.json"
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  run jq -r '.custom' "$TARGET/.claude/settings.local.json"
  [ "$output" = "value" ]
}

@test "install.sh adds gitignore entries for runtime state, worktrees, and local settings" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  run cat "$TARGET/.gitignore"
  [[ "$output" == *"_orch/state/"* ]]
  [[ "$output" == *"wt/"* ]]
  [[ "$output" == *".claude/settings.local.json"* ]]
}

@test "install.sh re-run (update) preserves the target's tuned config.json" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  jq '.thresholds.max_workers = 99' "$TARGET/_orch/config.json" > "$TARGET/_orch/config.json.tmp"
  mv "$TARGET/_orch/config.json.tmp" "$TARGET/_orch/config.json"

  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"preserved existing"* ]]
  run jq -r '.thresholds.max_workers' "$TARGET/_orch/config.json"
  [ "$output" = "99" ]
}

@test "install.sh re-run (update) preserves a persisted session name (issue #92 rv92 finding 4)" {
  # install.sh wipes _orch/state wholesale on every run (see "never copies
  # runtime state" above) -- the persisted session name (issue #92) must be
  # explicitly backed up and restored across that wipe, the same way
  # config.json already is, or an `orch up --name billing` gets silently
  # reverted to the hash default by the next re-install/upgrade.
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  mkdir -p "$TARGET/_orch/state"
  printf 'billing\n' > "$TARGET/_orch/state/session-name"

  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"preserved existing session name"* ]]
  [ "$(cat "$TARGET/_orch/state/session-name")" = "billing" ]
}

@test "install.sh re-run still refreshes the toolkit scripts themselves" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  echo "stale content" > "$TARGET/_orch/report.sh"

  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  ! grep -q "stale content" "$TARGET/_orch/report.sh"
  diff -q "$SRC/_orch/report.sh" "$TARGET/_orch/report.sh"
}

@test "install.sh warns about missing dependencies without failing" {
  # A PATH with the core utils install.sh itself needs (bash, coreutils, grep,
  # plus mktemp/find/mv for the atomic staged-copy) but none of the checked
  # deps (tmux/jq/claude/perl/git), so the warning path is hit without
  # install.sh's own execution breaking.
  STUBBIN="$BATS_TEST_TMPDIR/nodeps"
  mkdir -p "$STUBBIN"
  for bin in bash sh env cat mkdir rm cp chmod echo grep touch dirname basename mktemp find mv; do
    p="$(command -v "$bin")" && ln -s "$p" "$STUBBIN/$bin"
  done
  run env PATH="$STUBBIN" "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing dependency: tmux"* ]]
  [[ "$output" == *"missing dependency: jq"* ]]
  [[ "$output" == *"missing dependency: claude"* ]]
  [[ "$output" == *"missing dependency: perl"* ]]
  [[ "$output" == *"missing dependency: git"* ]]
}

@test "install.sh warns when the target is not a git repo root" {
  nogit="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$nogit"
  run "$INSTALL" "$nogit"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a git repo root"* ]]
}

@test "install.sh defaults the target to the current directory" {
  cd "$TARGET"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -d "$TARGET/_orch" ]
}

# --- Atomic replace / state-preservation (issue #91 review findings) ---------

@test "install.sh replaces a file via atomic rename (new inode), never overwrites in place" {
  # A process (heartbeat.sh, orch update itself) already reading the OLD file
  # by inode when a re-install/update rewrites it must keep reading the
  # ORIGINAL bytes to completion, never a half-overwritten file at a shifted
  # offset. Simulate that "already reading" process with a bare file
  # descriptor opened before the second install.sh run.
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  f="$TARGET/_orch/report.sh"
  before_inode="$(stat -c %i "$f")"
  before_content="$(cat "$f")"
  exec 9< "$f"

  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]

  after_inode="$(stat -c %i "$f")"
  [ "$before_inode" != "$after_inode" ]

  via_old_fd="$(cat <&9)"
  exec 9<&-
  [ "$via_old_fd" = "$before_content" ]
}

@test "install.sh never touches _orch/state on an update — runtime state survives" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  mkdir -p "$TARGET/_orch/state"
  echo '{"event":"done"}' > "$TARGET/_orch/state/events.jsonl"
  echo '{"spawns":3}' > "$TARGET/_orch/state/spend.json"
  echo '[]' > "$TARGET/_orch/state/queue.jsonl"
  echo "notes" > "$TARGET/_orch/state/master-notes.md"

  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]

  [ "$(cat "$TARGET/_orch/state/events.jsonl")" = '{"event":"done"}' ]
  [ "$(cat "$TARGET/_orch/state/spend.json")" = '{"spawns":3}' ]
  [ -f "$TARGET/_orch/state/queue.jsonl" ]
  [ "$(cat "$TARGET/_orch/state/master-notes.md")" = "notes" ]
}

@test "install.sh: a failure mid-copy never clobbers the target's tuned config.json" {
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  jq '.thresholds.max_workers = 99' "$TARGET/_orch/config.json" > "$TARGET/_orch/config.json.tmp"
  mv "$TARGET/_orch/config.json.tmp" "$TARGET/_orch/config.json"
  before_version="$(cat "$TARGET/.orch-version")"

  # A broken/incomplete "upstream" (missing tmux/ entirely) — install.sh must
  # fail loudly staging it, before ever touching the target.
  BROKEN="$BATS_TEST_TMPDIR/brokensrc"
  mkdir -p "$BROKEN"
  cp -R "$SRC/_orch" "$BROKEN/"
  cp "$SRC/install.sh" "$BROKEN/"
  cp "$SRC/VERSION" "$BROKEN/"

  run "$BROKEN/install.sh" "$TARGET"
  [ "$status" -ne 0 ]

  run jq -r '.thresholds.max_workers' "$TARGET/_orch/config.json"
  [ "$output" = "99" ]
  [ "$(cat "$TARGET/.orch-version")" = "$before_version" ]
}
