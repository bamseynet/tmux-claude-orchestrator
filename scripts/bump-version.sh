#!/usr/bin/env bash
# VERSION bump logic for the bump-version workflow (issue #200). Pure bash, no
# network except the injected `gh` lookup of PR labels; bash 3.2-safe.
#
#   bump-version.sh next <patch|minor|major> <X.Y.Z>   print the next version
#   bump-version.sh level                              stdin labels -> max level
#   bump-version.sh bump [repo-dir]                    compute from git history,
#                                                      write VERSION, print it
#
# `bump` takes base = the last commit that touched VERSION (a bump commit or a
# hand-written release, so a manual value is never re-bumped), then looks at
# base..HEAD: no runtime-path change -> prints nothing; otherwise the level is
# the highest `release:*` PR label among the runtime-touching commits (default patch).
set -euo pipefail

# Paths that ship in an install (keep in sync with on.push.paths in the workflow).
RUNTIME_PATHS=(_orch tmux orch install.sh uninstall.sh)

die() { echo "bump-version: $*" >&2; exit 1; }

cmd_next() { # <level> <version>
  local level="${1:-}" v="${2:-}" major minor patch
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be X.Y.Z, got '$v'"
  IFS=. read -r major minor patch <<<"$v"
  case "$level" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
    *) die "unknown level '$level'" ;;
  esac
  echo "$major.$minor.$patch"
}

cmd_level() { # stdin: one label per line
  local label level=patch
  while IFS= read -r label || [ -n "$label" ]; do
    case "$label" in
      release:major) level=major ;;
      release:minor) [ "$level" = major ] || level=minor ;;
    esac
  done
  echo "$level"
}

cmd_bump() { # [repo-dir]
  local dir="${1:-.}" base sha labels="" cur level new out
  cd "$dir"
  base="$(git log -1 --format=%H -- VERSION)"
  [ -n "$base" ] || die "no commit touches VERSION"
  # Fail loud on a malformed VERSION before doing anything else.
  cur="$(tr -d '[:space:]' <VERSION)"
  cmd_next patch "$cur" >/dev/null
  if [ -z "$(git diff --name-only "$base" HEAD -- "${RUNTIME_PATHS[@]}")" ]; then
    return 0
  fi
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # A failed lookup must not silently downgrade a release:major/minor to patch.
    out="$(gh api "repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY unset}/commits/$sha/pulls" \
      --jq '.[] | select(.merged_at != null) | .labels[].name')" || die "label lookup failed for $sha"
    labels="$labels$out
"
  done < <(git rev-list "$base..HEAD" -- "${RUNTIME_PATHS[@]}")
  level="$(printf '%s' "$labels" | cmd_level)"
  new="$(cmd_next "$level" "$cur")"
  printf '%s\n' "$new" >VERSION
  echo "$new"
}

case "${1:-}" in
  next) shift; cmd_next "$@" ;;
  level) cmd_level ;;
  bump) shift; cmd_bump "$@" ;;
  *) die "usage: $0 next <level> <X.Y.Z> | level | bump [repo-dir]" ;;
esac
