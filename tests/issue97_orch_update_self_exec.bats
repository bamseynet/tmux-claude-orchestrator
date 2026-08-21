#!/usr/bin/env bats
# End-to-end self-update test (issue #97): every existing orch_update.bats test
# runs $SRC/_orch/update.sh against a throwaway ORCH_ROOT, so the script under
# test is never the script actually being replaced. This file closes that gap:
# it builds a REAL vendored install (via install.sh, exactly as a user would
# get one), points it at a fake upstream carrying a higher VERSION, then runs
# ./orch update FROM INSIDE that install -- so _orch/update.sh (and orch, and
# install.sh) are the very files being rewritten while update.sh is still
# executing them. That self-referential shape is the only place the "bash
# re-reads a running script by byte offset from its inode" hazard can occur;
# see install.sh's staged-copy comment block. Fully hermetic: gh/git/tmux are
# stubbed (no network); curl/wget are stubbed to log-and-fail-loudly so an
# unexpected fallback path is never silently absent, it's a hard test failure.

SRC="$BATS_TEST_DIRNAME/.."

setup() {
  # This worker's own launch env sets ORCH_ROOT to ITS orchestrator's real
  # toolkit (the tmux-claude-orchestrator instance driving this very worker)
  # -- exactly the "inherited ORCH_ROOT" leak issue #68's guard in lib.sh
  # warns about. That guard only redirects STATE_DIR/WORKERS_DIR/etc, not
  # ORCH_ROOT/ORCH_DIR/CONFIG themselves, and `orch`'s own
  # `ORCH_ROOT="${ORCH_ROOT:-$here}"` never re-resolves an already-set
  # ORCH_ROOT from $0's dirname -- so without this unset, every `./orch`
  # invocation below would silently operate on the unrelated ambient
  # toolkit instead of $TARGET, defeating the entire point of this fixture
  # (self-referential update: the running script IS the file being
  # replaced). Confirmed by hand: this test reported "current version: 9.9.9"
  # before ever applying anything, because it was reading the WRONG root's
  # .orch-version.
  unset ORCH_ROOT

  REALGIT="$(command -v git)"
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  GIT_CLONE_LOG="$BATS_TEST_TMPDIR/git-clone.log"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  WGET_LOG="$BATS_TEST_TMPDIR/wget.log"
  : > "$GH_LOG"; : > "$GIT_CLONE_LOG"; : > "$CURL_LOG"; : > "$WGET_LOG"

  UPSTREAM_VERSION="9.9.9"
  MARKER="ORCH_UPSTREAM_MARKER_issue97_$$"
  export GH_LOG GIT_CLONE_LOG CURL_LOG WGET_LOG UPSTREAM_VERSION MARKER

  # --- 1. Build a REAL vendored install, the way a user would (real
  # install.sh, real cp, no stubs yet -- this is not the code path under
  # test, it's the fixture setup for it).
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"
  "$SRC/install.sh" "$TARGET" >/dev/null

  # --- 2. Build a fake "upstream": a full copy of this toolkit's tree with a
  # bumped VERSION and a marker byte-sequence appended to update.sh itself --
  # the exact file that will be running (as a live bash process) at the
  # moment install.sh, invoked from inside that same process, rewrites it.
  # A pure trailing comment: parses fine, changes nothing about behavior, but
  # proves after the fact that the TARGET's update.sh bytes actually became
  # the UPSTREAM's bytes (real script agreement), not just that .orch-version
  # was bumped.
  UPSTREAM="$BATS_TEST_TMPDIR/upstream"
  mkdir -p "$UPSTREAM"
  cp -R "$SRC/_orch" "$UPSTREAM/"
  cp -R "$SRC/tmux" "$UPSTREAM/"
  cp "$SRC/orch" "$UPSTREAM/"
  cp "$SRC/install.sh" "$UPSTREAM/"
  printf '%s\n' "$UPSTREAM_VERSION" > "$UPSTREAM/VERSION"
  printf '\n# %s\n' "$MARKER" >> "$UPSTREAM/_orch/update.sh"
  export UPSTREAM

  # --- 3. Stubs. gh reports the bumped version; git clone hands back the
  # fake upstream tree (never the network); tmux reports no live session;
  # curl/wget are loudly-failing recording stubs -- present on PATH (not
  # merely absent) so a fallback path that fires unexpectedly is a hard
  # failure, never a silent no-op.
  cat > "$STUBBIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
if [ "\$1" = "api" ]; then
  printf '%s' "$UPSTREAM_VERSION"
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBBIN/gh"

  cat > "$STUBBIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "clone" ]; then
  echo "git \$*" >> "$GIT_CLONE_LOG"
  dest="\${*: -1}"
  mkdir -p "\$dest"
  cp -R "$UPSTREAM/." "\$dest/"
  exit 0
fi
exec "$REALGIT" "\$@"
EOF
  chmod +x "$STUBBIN/git"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  has-session) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  cat > "$STUBBIN/curl" <<EOF
#!/usr/bin/env bash
echo "UNEXPECTED curl \$*" >> "$CURL_LOG"
echo "STUB: curl must never be called -- gh is present on PATH" >&2
exit 1
EOF
  chmod +x "$STUBBIN/curl"

  cat > "$STUBBIN/wget" <<EOF
#!/usr/bin/env bash
echo "UNEXPECTED wget \$*" >> "$WGET_LOG"
echo "STUB: wget must never be called -- update.sh never uses it" >&2
exit 1
EOF
  chmod +x "$STUBBIN/wget"
}

# --- 4. Tune the target exactly like a real operator would, THEN run
# ./orch update from inside the target itself -- ORCH_ROOT resolves from
# $0's own dirname (see orch's `here=`), so this is genuinely
# self-referential: the update.sh process reading/executing this run IS the
# file install.sh rewrites out from under it.

@test "orch update, run from inside its own real vendored install, replaces itself correctly end-to-end" {
  jq '.thresholds.max_workers = 99' "$TARGET/_orch/config.json" > "$TARGET/_orch/config.json.tmp"
  mv "$TARGET/_orch/config.json.tmp" "$TARGET/_orch/config.json"

  mkdir -p "$TARGET/_orch/state"
  echo '{"event":"done"}' > "$TARGET/_orch/state/events.jsonl"
  echo '{"spawns":3}' > "$TARGET/_orch/state/spend.json"
  printf 'billing\n' > "$TARGET/_orch/state/session-name"

  before_version="$(cat "$TARGET/.orch-version")"

  # The core hazard (issue #91/#97): a bash process reading _orch/update.sh by
  # byte offset from ITS OWN inode, while install.sh -- invoked BY that same
  # process, mid-script, via _apply_update -- rewrites the file underneath it.
  # `run` forks a real child process to exec ./orch, so we cannot literally
  # inspect update.sh's own in-flight read position from here. What we CAN
  # assert, deterministically, is the invariant install.sh's atomic-rename
  # design exists to guarantee: any reader already holding the OLD file open
  # (by inode, at the moment the swap happens) must keep seeing the complete,
  # untouched original bytes, and the path must resolve to a NEW inode
  # afterward. Hold an fd open on the target's update.sh -- standing in for
  # "the process currently executing it" -- across the run, exactly as
  # install.bats's "replaces a file via atomic rename" test does for
  # report.sh. A regression to plain `cp` (same inode, truncate + overwrite
  # in place) flips both checks: the fd sees the NEW content, not the old,
  # and the inode never changes.
  update_path="$TARGET/_orch/update.sh"
  before_update_inode="$(stat -c %i "$update_path")"
  before_update_content="$(cat "$update_path")"
  exec 9< "$update_path"

  cd "$TARGET"
  PATH="$STUBBIN:$PATH" run ./orch update

  after_update_inode="$(stat -c %i "$update_path")"
  via_old_fd="$(cat <&9)"
  exec 9<&-
  [ "$before_update_inode" != "$after_update_inode" ]
  [ "$via_old_fd" = "$before_update_content" ]

  # Correct exit status: a successful update must not report failure.
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated $before_version -> $UPSTREAM_VERSION"* ]]

  # Version stamp and the scripts agree afterward.
  [ "$(cat "$TARGET/.orch-version")" = "$UPSTREAM_VERSION" ]
  grep -q "$MARKER" "$TARGET/_orch/update.sh"
  diff -q "$UPSTREAM/_orch/update.sh" "$TARGET/_orch/update.sh"
  diff -q "$UPSTREAM/orch" "$TARGET/orch"

  # _orch/state/ survived.
  [ "$(cat "$TARGET/_orch/state/events.jsonl")" = '{"event":"done"}' ]
  [ "$(cat "$TARGET/_orch/state/spend.json")" = '{"spawns":3}' ]
  [ "$(cat "$TARGET/_orch/state/session-name")" = "billing" ]

  # Tuned config.json survived.
  run jq -r '.thresholds.max_workers' "$TARGET/_orch/config.json"
  [ "$output" = "99" ]

  # No fragment of a half-written script executed: exactly one clone, one gh
  # api call, curl/wget never invoked, and no output from an incomplete/
  # corrupted script (a shifted-offset re-read would show up as a bash parse
  # error or truncated/garbled output on stderr, not a clean "updated" line).
  [ "$(grep -c '^git clone' "$GIT_CLONE_LOG")" -eq 1 ]
  [ "$(grep -c '^gh api' "$GH_LOG")" -eq 1 ]
  [ ! -s "$CURL_LOG" ]
  [ ! -s "$WGET_LOG" ]
  [[ "$output" != *"syntax error"* ]]
  [[ "$output" != *"unexpected end of file"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

@test "orch update --check, run from inside its own real vendored install, reports availability without touching anything" {
  before_version="$(cat "$TARGET/.orch-version")"

  cd "$TARGET"
  PATH="$STUBBIN:$PATH" run ./orch update --check

  [ "$status" -eq 0 ]
  [[ "$output" == *"update available"* ]]
  [ ! -s "$GIT_CLONE_LOG" ]
  [ "$(cat "$TARGET/.orch-version")" = "$before_version" ]
  diff -q "$SRC/_orch/update.sh" "$TARGET/_orch/update.sh"
  ! grep -q "$MARKER" "$TARGET/_orch/update.sh"
}
