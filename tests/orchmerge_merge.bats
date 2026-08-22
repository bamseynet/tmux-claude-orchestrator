#!/usr/bin/env bats
# Hermetic tests for _orch/merge.sh (issue #36): opt-in CI-gated auto-merge.
# `gh` is fully stubbed (no real GitHub calls, ever) and `git` is stubbed only for
# `push` (no real network) while delegating every other subcommand to the real
# git binary against a throwaway local repo, so branch/PR-adjacent state (branch
# existence, etc.) stays real and meaningful. No real merge, push, or network
# call is ever made.

MERGE="$BATS_TEST_DIRNAME/../_orch/merge.sh"

# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  REALGIT="$(command -v git)"
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GIT_LOG"
  : > "$GH_LOG"
  export GIT_LOG GH_LOG

  cat > "$STUBBIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "push" ]; then
    echo "git \$*" >> "$GIT_LOG"
    exit "\${GIT_PUSH_EXIT:-0}"
  fi
done
exec "$REALGIT" "\$@"
EOF
  chmod +x "$STUBBIN/git"

  # GH_EXISTING_PR=1        -> `gh pr view --json url -q .url` returns a PR (reuse, no create)
  # GH_MERGEABLE=<val>      -> mergeable field on `gh pr view` full JSON (default MERGEABLE)
  # GH_MERGE_STATE=<val>    -> mergeStateStatus field (default CLEAN)
  # GH_CHECKS_MODE=pass|fail|pending -> `gh pr checks` outcome (default pass)
  # GH_MERGE_FAIL=1         -> `gh pr merge` exits nonzero
  cat > "$STUBBIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [[ "$*" == *"-q .url"* ]]; then
    if [ "${GH_EXISTING_PR:-0}" = "1" ]; then
      echo "https://github.com/org/repo/pull/1"
    fi
    exit 0
  fi
  jq -n --arg mergeable "${GH_MERGEABLE:-MERGEABLE}" --arg state "${GH_MERGE_STATE:-CLEAN}" \
    '{number:1,url:"https://github.com/org/repo/pull/1",state:"OPEN",mergeable:$mergeable,mergeStateStatus:$state}'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://github.com/org/repo/pull/1"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
  case "${GH_CHECKS_MODE:-pass}" in
    pass)    echo '[{"name":"ci","bucket":"pass","state":"SUCCESS"}]' ;;
    fail)    echo '[{"name":"ci","bucket":"fail","state":"FAILURE"}]' ;;
    pending) echo '[{"name":"ci","bucket":"pending","state":"IN_PROGRESS"}]' ;;
  esac
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  if [ "${GH_MERGE_FAIL:-0}" = "1" ]; then
    echo "merge blocked by branch protection" >&2
    exit 1
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBBIN/gh"

  PATH="$STUBBIN:$PATH"
  export PATH

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cat > "$ORCH_ROOT/_orch/config.json" <<'JSON'
{
  "merge": {
    "auto": false,
    "required_checks": [],
    "poll_interval_seconds": 1,
    "timeout_seconds": 2
  }
}
JSON

  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  git init -q -b main "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email test@example.com
  git -C "$PROJECT_ROOT" config user.name test
  echo hello > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init
}

mkbranch() { # <id>
  local branch
  branch="$(ORCH_ROOT="$ORCH_ROOT" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch "'"$1"'"')"
  git -C "$PROJECT_ROOT" branch "$branch" main >/dev/null
}

@test "merge.sh fails for a nonexistent branch" {
  run "$MERGE" nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "merge.sh falls back to the legacy orch/<id> branch when the namespaced one doesn't exist (issue #86 back-compat)" {
  git -C "$PROJECT_ROOT" branch "orch/w0legacy" main >/dev/null
  run "$MERGE" w0legacy
  [ "$status" -eq 0 ]
  grep -q "push -u origin orch/w0legacy" "$GIT_LOG"
}

@test "merge.sh without --auto only pushes + opens a PR, never merges" {
  mkbranch w1
  run "$MERGE" w1
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://github.com/org/repo/pull/1"* ]]
  grep -q "push" "$GIT_LOG"
  refute_grep_in_existing "pr merge" "$GH_LOG"
  [ ! -f "$ORCH_ROOT/_orch/state/events.jsonl" ]
}

@test "merge.sh reuses an existing PR instead of creating a new one" {
  mkbranch w2
  GH_EXISTING_PR=1 run "$MERGE" w2
  [ "$status" -eq 0 ]
  refute_grep_in_existing "pr create" "$GH_LOG"
}

@test "merge.sh --auto merges and emits a merged event when checks pass" {
  mkbranch w3
  GH_CHECKS_MODE=pass run "$MERGE" w3 --auto
  [ "$status" -eq 0 ]
  grep -q "pr merge" "$GH_LOG"
  grep -q -- "--squash" "$GH_LOG"
  grep -q -- "--delete-branch" "$GH_LOG"

  run jq -r '.status' "$ORCH_ROOT/_orch/state/workers/w3.json"
  [ "$output" = "merged" ]

  run jq -rs '.[-1].event' "$ORCH_ROOT/_orch/state/events.jsonl"
  [ "$output" = "merged" ]
  run jq -rs '.[-1].event' "$ORCH_ROOT/_orch/state/inbox.jsonl"
  [ "$output" = "merged" ]
}

@test "merge.sh honors config merge.auto=true without the --auto flag" {
  mkbranch w4
  jq '.merge.auto = true' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"

  GH_CHECKS_MODE=pass run "$MERGE" w4
  [ "$status" -eq 0 ]
  grep -q "pr merge" "$GH_LOG"
}

@test "merge.sh --auto blocks (does not merge) when a required check fails" {
  mkbranch w5
  GH_CHECKS_MODE=fail run "$MERGE" w5 --auto
  [ "$status" -ne 0 ]
  refute_grep_in_existing "pr merge" "$GH_LOG"

  run jq -r '.status' "$ORCH_ROOT/_orch/state/workers/w5.json"
  [ "$output" = "blocked" ]
  run jq -rs '.[-1].event' "$ORCH_ROOT/_orch/state/events.jsonl"
  [ "$output" = "merge-blocked" ]
}

@test "merge.sh --auto times out and blocks when checks never finish" {
  mkbranch w6
  GH_CHECKS_MODE=pending run "$MERGE" w6 --auto
  [ "$status" -ne 0 ]
  refute_grep_in_existing "pr merge" "$GH_LOG"

  run jq -r '.status' "$ORCH_ROOT/_orch/state/workers/w6.json"
  [ "$output" = "blocked" ]
  run jq -rs '.[-1].reason' "$ORCH_ROOT/_orch/state/events.jsonl"
  [[ "$output" == *"timed out"* ]]
}

@test "merge.sh --auto refuses a CONFLICTING PR without waiting on checks" {
  mkbranch w7
  GH_MERGEABLE=CONFLICTING run "$MERGE" w7 --auto
  [ "$status" -ne 0 ]
  refute_grep_in_existing "pr checks" "$GH_LOG"
  refute_grep_in_existing "pr merge" "$GH_LOG"

  run jq -r '.status' "$ORCH_ROOT/_orch/state/workers/w7.json"
  [ "$output" = "blocked" ]
  run jq -rs '.[-1].event' "$ORCH_ROOT/_orch/state/events.jsonl"
  [ "$output" = "merge-blocked" ]
}

@test "merge.sh --auto refuses a DIRTY PR without waiting on checks" {
  mkbranch w8
  GH_MERGE_STATE=DIRTY run "$MERGE" w8 --auto
  [ "$status" -ne 0 ]
  refute_grep_in_existing "pr checks" "$GH_LOG"

  run jq -r '.status' "$ORCH_ROOT/_orch/state/workers/w8.json"
  [ "$output" = "blocked" ]
}

@test "merge.sh --auto blocks when gh pr merge itself fails (e.g. branch protection)" {
  mkbranch w9
  GH_CHECKS_MODE=pass GH_MERGE_FAIL=1 run "$MERGE" w9 --auto
  [ "$status" -ne 0 ]

  run jq -r '.status' "$ORCH_ROOT/_orch/state/workers/w9.json"
  [ "$output" = "blocked" ]
  run jq -rs '.[-1].event' "$ORCH_ROOT/_orch/state/events.jsonl"
  [ "$output" = "merge-blocked" ]
}

@test "merge.sh honors merge.required_checks: ignores non-required check names" {
  mkbranch w10
  jq '.merge.required_checks = ["ci"]' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"

  GH_CHECKS_MODE=pass run "$MERGE" w10 --auto
  [ "$status" -eq 0 ]
  grep -q "pr merge" "$GH_LOG"
}

# --- shared refute helper (issue #134): missing-file semantics ----------------
# refute_grep and refute_grep_in_existing differ ONLY on a missing file, which
# is exactly the case PR #130's file-local refute_grep got wrong (grep -c on a
# nonexistent path prints nothing and exits 2; `|| true` swallowed that, leaving
# `[ "" -eq 0 ]`, a bash error rather than a pass/fail). Pin both directions.

@test "refute_grep treats a missing file as absent (does not error)" {
  refute_grep "anything" "$BATS_TEST_TMPDIR/does-not-exist"
}

@test "refute_grep_in_existing fails when the file is missing" {
  run refute_grep_in_existing "anything" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -ne 0 ]
}

@test "refute_grep_in_existing passes when the file exists and the pattern is absent" {
  echo "unrelated content" > "$BATS_TEST_TMPDIR/present"
  refute_grep_in_existing "anything" "$BATS_TEST_TMPDIR/present"
}

@test "refute_grep fails when the pattern is present" {
  echo "found it" > "$BATS_TEST_TMPDIR/present"
  run refute_grep "found it" "$BATS_TEST_TMPDIR/present"
  [ "$status" -ne 0 ]
}

@test "refute_grep fails on a grep error rather than passing vacuously" {
  echo "unrelated content" > "$BATS_TEST_TMPDIR/present2"
  # An invalid BRE makes grep exit 2; that must NOT read as "pattern absent".
  run refute_grep 'a\{1' "$BATS_TEST_TMPDIR/present2"
  [ "$status" -ne 0 ]
}

@test "refute_grep fails on a missing/empty path argument instead of passing vacuously" {
  # A typo'd variable expands to nothing; that is a caller bug, not an absence.
  run refute_grep "anything" ""
  [ "$status" -ne 0 ]
  run refute_grep "anything"
  [ "$status" -ne 0 ]
  run refute_grep_in_existing "anything" ""
  [ "$status" -ne 0 ]
}

@test "refute_alive fails on a missing/empty pid argument instead of passing vacuously" {
  # `kill -0 ""` fails, so without a guard an unset pid reads as "not running".
  run refute_alive ""
  [ "$status" -ne 0 ]
  run refute_alive
  [ "$status" -ne 0 ]
}

@test "refute_grep fails on an empty pattern instead of passing vacuously" {
  # An empty pattern matches every line, so it only LOOKS like a real check:
  # against an empty file it would silently pass. Treat it as the caller bug
  # it is, in both directions.
  : > "$BATS_TEST_TMPDIR/empty"
  run refute_grep "" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -ne 0 ]
  run refute_grep_in_existing "" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -ne 0 ]
}

@test "refute_alive fails on a non-numeric pid instead of passing vacuously" {
  # `kill -0 not-a-pid` fails the same way a dead pid does, so an unguarded
  # helper would read a typo'd pid as "not running".
  run refute_alive "not-a-pid"
  [ "$status" -ne 0 ]
}

@test "refute_alive fails while the pid is running and passes once it exits" {
  # The point of the helper, pinned in both directions: without this, dropping
  # or inverting its `!` would leave the suite green.
  #
  # The canary is reaped BEFORE the first assertion, and its verdict stashed,
  # deliberately: under bats' set -e a failing assertion aborts the body, so a
  # kill placed after it never runs and `sleep` survives holding bats' output
  # pipe for its full 30s (measured: the file went ~13s -> ~43s). A teardown()
  # is not the fix here -- this suite has none, and bats-core owns EXIT on the
  # test process, the same quirk .github/workflows/ci.yml already documents.
  # Cleanup-before-assert needs no trap and cannot be skipped.
  sleep 30 >/dev/null 2>&1 &
  bg_pid=$!
  run refute_alive "$bg_pid"
  alive_status="$status"
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true

  [ "$alive_status" -ne 0 ]   # was running -> helper must have failed
  refute_alive "$bg_pid"      # now reaped -> helper must pass
}
