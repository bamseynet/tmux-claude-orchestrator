#!/usr/bin/env bats
# Hermetic tests for scripts/bump-version.sh (issue #200): automatic VERSION
# bumps on merge to main. No network; `gh` is stubbed; git repos are throwaway.

BUMP="$BATS_TEST_DIRNAME/../scripts/bump-version.sh"
UPDATE="$BATS_TEST_DIRNAME/../_orch/update.sh"
WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/bump-version.yml"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  export GITHUB_REPOSITORY="o/r"
  # Stub gh: `gh api repos/o/r/commits/<sha>/pulls ...` prints the labels
  # listed in $LABELS_DIR/<sha> (one per line), if that file exists.
  cat > "$STUBBIN/gh" <<EOS
#!/usr/bin/env bash
[ -f "$BATS_TEST_TMPDIR/gh_fail" ] && { echo "HTTP 403" >&2; exit 1; }
sha="\${2##*/commits/}"; sha="\${sha%%/*}"
[ -f "$BATS_TEST_TMPDIR/labels/\$sha" ] && cat "$BATS_TEST_TMPDIR/labels/\$sha"
exit 0
EOS
  chmod +x "$STUBBIN/gh"
  mkdir -p "$BATS_TEST_TMPDIR/labels"
  export PATH="$STUBBIN:$PATH"
}

mkrepo() { # builds $R with a bump commit at 1.2.3
  R="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$R"
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  mkdir -p "$R/_orch" "$R/tests"
  echo "1.2.3" > "$R/VERSION"; echo a > "$R/_orch/a.sh"
  git -C "$R" add -A; git -C "$R" commit -qm "chore(release): bump VERSION to 1.2.3"
}
commit() { # <file> [label]
  mkdir -p "$(dirname "$R/$1")"; echo "$RANDOM" >> "$R/$1"
  git -C "$R" add -A; git -C "$R" commit -qm "change $1"
  [ -z "${2:-}" ] || echo "$2" > "$BATS_TEST_TMPDIR/labels/$(git -C "$R" rev-parse HEAD)"
}

@test "next: patch/minor/major" {
  [ "$("$BUMP" next patch 1.2.3)" = 1.2.4 ]
  [ "$("$BUMP" next minor 1.2.3)" = 1.3.0 ]
  [ "$("$BUMP" next major 1.2.3)" = 2.0.0 ]
}

@test "next: no carry from patch, 0.9.9 -> 0.9.10 / 0.10.0" {
  [ "$("$BUMP" next patch 0.9.9)" = 0.9.10 ]
  [ "$("$BUMP" next minor 0.9.9)" = 0.10.0 ]
}

@test "next: output is a valid, newer version per update.sh (incl. sort -V case)" {
  lv="$(sed -n '/^_looks_like_version()/p' "$UPDATE")"
  newer="$(sed -n '/^_is_newer()/,/^}/p' "$UPDATE")"
  for case in "patch 0.9.9" "minor 0.9.9" "major 0.9.9" "patch 1.2.3"; do
    read -r lvl cur <<<"$case"
    out="$("$BUMP" next "$lvl" "$cur")"
    run bash -c "$lv"$'\n'"$newer"$'\n'"_looks_like_version '$out' && _is_newer '$cur' '$out'"
    [ "$status" -eq 0 ]
  done
}

@test "next: malformed VERSION or unknown level fails with no output" {
  for v in 0.2 0.2.0-rc1 "" v1.2.3 1.2.3.4; do
    run bash -c '"$0" next patch "$1" 2>/dev/null' "$BUMP" "$v"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
  run bash -c '"$0" next huge 1.2.3 2>/dev/null' "$BUMP"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "next twice yields strictly increasing distinct versions" {
  a="$("$BUMP" next patch 0.2.0)"; b="$("$BUMP" next patch "$a")"
  [ "$a" = 0.2.1 ]; [ "$b" = 0.2.2 ]
}

@test "level: default patch, minor, major wins, unrelated ignored" {
  [ "$(printf '' | "$BUMP" level)" = patch ]
  [ "$(printf 'bug\nrelease:minor\n' | "$BUMP" level)" = minor ]
  [ "$(printf 'release:minor\nrelease:major\n' | "$BUMP" level)" = major ]
  [ "$(printf 'release:major\nrelease:minor\n' | "$BUMP" level)" = major ]
  [ "$(printf 'enhancement\n' | "$BUMP" level)" = patch ]
}

@test "bump: runtime change since last bump -> patch, VERSION written" {
  mkrepo; commit _orch/a.sh
  run "$BUMP" bump "$R"
  [ "$status" -eq 0 ]
  [ "$output" = 1.2.4 ]
  [ "$(cat "$R/VERSION")" = 1.2.4 ]
}

@test "bump: highest label across the coalesced range wins" {
  mkrepo; commit _orch/a.sh release:minor; commit orch; commit install.sh
  run "$BUMP" bump "$R"
  [ "$output" = 1.3.0 ]
  [ "$(cat "$R/VERSION")" = 1.3.0 ]
}

@test "bump: failed label lookup fails loud, VERSION untouched" {
  mkrepo; commit _orch/a.sh release:major
  touch "$BATS_TEST_TMPDIR/gh_fail"
  run "$BUMP" bump "$R"
  [ "$status" -eq 1 ]
  [ "$(cat "$R/VERSION")" = 1.2.3 ]
}

@test "bump: release label on a non-runtime commit is ignored" {
  mkrepo; commit README.md release:major; commit _orch/a.sh
  run "$BUMP" bump "$R"
  [ "$output" = 1.2.4 ]
}

@test "bump: docs/tests/.github-only range -> no bump" {
  mkrepo; commit README.md; commit tests/x.bats; commit .github/workflows/ci.yml
  run "$BUMP" bump "$R"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$R/VERSION")" = 1.2.3 ]
}

@test "bump: commits before a hand-written VERSION change are not re-bumped" {
  mkrepo; commit _orch/a.sh
  echo 2.0.0 > "$R/VERSION"; git -C "$R" commit -qam "release: 2.0.0"
  run "$BUMP" bump "$R"
  [ -z "$output" ]
  [ "$(cat "$R/VERSION")" = 2.0.0 ]
}

@test "bump: malformed VERSION fails loud with no write" {
  mkrepo; echo 0.2 > "$R/VERSION"; git -C "$R" commit -qam "hand edit"
  commit _orch/a.sh
  run "$BUMP" bump "$R"
  [ "$status" -eq 1 ]
  [ "$(cat "$R/VERSION")" = 0.2 ]
}

@test "concurrent bumps: loser's push is rejected; rebase + re-run gives next version" {
  mkrepo
  git clone -q --bare "$R" "$BATS_TEST_TMPDIR/origin.git"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/c1"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/c2"
  for c in c1 c2; do
    git -C "$BATS_TEST_TMPDIR/$c" config user.email t@t
    git -C "$BATS_TEST_TMPDIR/$c" config user.name t
    echo "$c" >> "$BATS_TEST_TMPDIR/$c/_orch/$c.sh"
    git -C "$BATS_TEST_TMPDIR/$c" add -A
  done
  # c1 pushes a runtime change, c2 has its own; both then bump from the same base
  git -C "$BATS_TEST_TMPDIR/c1" commit -qam "c1 change"
  git -C "$BATS_TEST_TMPDIR/c2" commit -qam "c2 change"
  for c in c1 c2; do
    d="$BATS_TEST_TMPDIR/$c"
    v="$("$BUMP" bump "$d")"; [ "$v" = 1.2.4 ]
    git -C "$d" commit -qam "chore(release): bump VERSION to $v"
  done
  git -C "$BATS_TEST_TMPDIR/c1" push -q origin HEAD:main
  run git -C "$BATS_TEST_TMPDIR/c2" push -q origin HEAD:main
  [ "$status" -ne 0 ]
  d="$BATS_TEST_TMPDIR/c2"
  git -C "$d" reset -q --hard HEAD~1
  git -C "$d" pull -q --rebase origin main
  # the rebased tip already carries c1's bump and c2's change sits before it
  # only if it was pushed; here c2's change is after c1's bump, so bump again.
  v="$("$BUMP" bump "$d")"
  [ "$v" = 1.2.5 ]
}

@test "update e2e: bumped VERSION is seen as an update by _is_newer" {
  v="$("$BUMP" next patch 0.2.0)"
  run bash -c "$(sed -n '/^_is_newer()/,/^}/p' "$UPDATE")"$'\n'"_is_newer 0.2.0 '$v'"
  [ "$status" -eq 0 ]
}

@test "workflow: static guards (triggers, permissions, concurrency)" {
  [ -f "$WORKFLOW" ]
  run grep -cE '^\s*pull_request' "$WORKFLOW"
  [ "$output" = 0 ]
  grep -qE '^permissions: \{\}' "$WORKFLOW"
  [ "$(grep -c 'contents: write' "$WORKFLOW")" -eq 1 ]
  grep -q 'cancel-in-progress: false' "$WORKFLOW"
  grep -q 'concurrency:' "$WORKFLOW"
  grep -q "github.actor != 'github-actions\[bot\]'" "$WORKFLOW"
  # VERSION must never be in the trigger paths (bump can't retrigger itself)
  run bash -c "sed -n '/^    paths:/,/^permissions:/p' '$WORKFLOW' | grep -c VERSION"
  [ "$output" = 0 ]
  # contents: write only inside the job (after `jobs:`)
  [ "$(sed -n '/^jobs:/,$p' "$WORKFLOW" | grep -c 'contents: write')" -eq 1 ]
}
