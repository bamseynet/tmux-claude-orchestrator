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

# Portable inode lookup (GNU stat: -c %i; BSD/macOS stat: -f %i also gives the
# inode number). Same defensive shape as lib.sh's _lock_mtime: gate on each
# attempt's own exit status rather than a bare `||`, since a failing GNU stat
# invocation on a BSD box would otherwise still print unrelated garbage before
# the fallback runs.
_inode() { # <path> -> inode number, or empty/failure
  local out
  out="$(stat -c %i "$1" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
  out="$(stat -f %i "$1" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
  return 1
}

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
  # install.sh stages via `cp -R`, which preserves the SOURCE's mode -- so if
  # UPSTREAM's scripts were already executable (as this fixture builds them,
  # copied straight from $SRC), install.sh's own `chmod +x` step (install.sh
  # ~line 81) could be missing entirely and the target would STILL end up
  # executable purely by inheritance, silently defeating the `-x` assertion
  # below. Strip the bit here so that assertion actually exercises install.sh
  # setting it, not merely preserving what was already there.
  chmod -x "$UPSTREAM/orch" "$UPSTREAM/_orch/"*.sh
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
  # OBSERVE this live rather than inferring it from a bystander fd: bash keeps
  # the currently-executing script's own file open for the ENTIRE run (verified
  # by hand: `ls -la /proc/$$/fd` inside a running `bash script.sh` shows fd
  # 255 -> script.sh throughout, including while a child process runs) -- that
  # IS the exact fd this hazard is about. Slow the version-fetch step (well
  # BEFORE install.sh ever runs) so this test can reliably catch the live
  # process's fd 255 both before AND after the on-disk path gets swapped out
  # from under it, without a fixed-offset sleep racing the swap itself.
  update_path="$TARGET/_orch/update.sh"
  before_update_inode="$(_inode "$update_path")"

  cat > "$STUBBIN/gh" <<GHEOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
if [ "\$1" = "api" ]; then
  sleep 0.4
  printf '%s' "$UPSTREAM_VERSION"
  exit 0
fi
exit 0
GHEOF
  chmod +x "$STUBBIN/gh"

  cd "$TARGET"
  run_out="$BATS_TEST_TMPDIR/run.out"
  : > "$run_out"
  # `exec` as the subshell's ONLY/last statement lets bash's tail-exec
  # optimization replace the subshell process itself with ./orch (and then,
  # via orch's own `exec _orch/update.sh`, with update.sh) -- so $! below is
  # genuinely update.sh's own PID, not a wrapper's. Adding any trailing
  # command here (e.g. `; echo $? >file`) defeats that optimization and
  # silently makes the fd-255 checks below observe the wrong process --
  # confirmed by hand: with a trailing command, this test's fd/inode
  # assertion never fires because bg_pid is a subshell wrapper's own PID.
  ( PATH="$STUBBIN:$PATH" exec ./orch update ) > "$run_out" 2>&1 &
  bg_pid=$!

  has_procfs=0
  [ -d /proc/self/fd ] && has_procfs=1

  observed_live_process_holding_old_inode_after_path_swapped=0
  if [ "$has_procfs" -eq 1 ]; then
    # No sleep in the loop body: the post-swap window (mv-loop finishes ->
    # process exit) is short, and under load a 1-2ms sleep can overshoot it
    # entirely. A tight busy-poll (stat/kill overhead alone paces it, sub-ms
    # per iteration) maximizes the chance of landing inside that window; the
    # 0.4s gh sleep above gives plenty of headroom before it even opens.
    # Capped by wall-clock, not just iteration count, so this can't hang.
    deadline=$(($(date +%s%N) + 3000000000))
    while [ "$(date +%s%N)" -lt "$deadline" ]; do
      kill -0 "$bg_pid" 2>/dev/null || break
      fd_target="/proc/$bg_pid/fd/255"
      if [ -r "$fd_target" ]; then
        fd_inode="$(stat -L -c %i "$fd_target" 2>/dev/null || true)"
        cur_path_inode="$(_inode "$update_path" || true)"
        if [ "$fd_inode" = "$before_update_inode" ] && [ -n "$cur_path_inode" ] \
           && [ "$cur_path_inode" != "$before_update_inode" ]; then
          observed_live_process_holding_old_inode_after_path_swapped=1
          break
        fi
      fi
    done
  fi

  wait "$bg_pid"
  status=$?
  output="$(cat "$run_out")"

  # /proc is Linux-only; CI is ubuntu-only (this repo's other GNU-only stat
  # sites, e.g. install.bats, rely on the same fact) but a contributor running
  # bats on macOS should get a skip here, not a false failure, since there is
  # no portable equivalent to inspecting another live process's fd table.
  if [ "$has_procfs" -eq 1 ]; then
    # THE ACTUAL OBSERVATION, not a proxy for it: the SAME live process (its
    # own fd 255, not an fd the test opened) was still reading update.sh's
    # ORIGINAL inode at a moment when the on-disk PATH already resolved to a
    # DIFFERENT (new) inode. That is "a running script kept reading its
    # original inode while the on-disk path changed" -- caught live, mid-run,
    # not inferred from the final state afterward.
    [ "$observed_live_process_holding_old_inode_after_path_swapped" -eq 1 ]
  else
    skip "no /proc on this platform -- cannot observe another process's live fd table"
  fi

  # Correct exit status: a successful update must not report failure.
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated $before_version -> $UPSTREAM_VERSION"* ]]

  # Version stamp and the scripts agree afterward.
  [ "$(cat "$TARGET/.orch-version")" = "$UPSTREAM_VERSION" ]
  grep -q "$MARKER" "$TARGET/_orch/update.sh"
  diff -q "$UPSTREAM/_orch/update.sh" "$TARGET/_orch/update.sh"
  diff -q "$UPSTREAM/orch" "$TARGET/orch"
  diff -r "$UPSTREAM/tmux" "$TARGET/tmux"

  # The swapped-in scripts must actually be executable, not just byte-for-byte
  # correct -- cp preserves the source file's mode, so a dropped `chmod +x` in
  # install.sh's staging step (install.sh:81) would leave install.bats's own
  # `[ -x ... ]` check passing too (its SOURCE tree already has the bit set)
  # while a real update out of a git clone (which does not preserve +x through
  # this staging path the same way) bricks the install. Assert it here, on the
  # end-to-end path, explicitly.
  [ -x "$TARGET/orch" ]
  [ -x "$TARGET/_orch/update.sh" ]

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
