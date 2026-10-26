# Shared fake-git fixture (issue #180).
#
# One parameterised `git` PATH stub instead of the same heredoc copy-pasted
# into 17 bats files. Load per-file, like fake-tmux.bash:
#
#   # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
#   source "$BATS_TEST_DIRNAME/helpers/fake-git.bash"
#   install_fake_git "$STUBBIN" [mode]
#
# Every mode parses an optional leading `-C <dir>` once (offset i=2) and exits 0
# for anything it does not emulate. The modes are deliberately separate stubs,
# not one stub doing all three: a test's reliance on `worktree add` creating a
# dir vs `worktree remove` deleting one should stay visible at the call site.
#
#   add (default)  spawn tests. `worktree add` mkdirs the path: the first
#                  positional after `add`, skipping `-b/-B <branch>` and flags
#                  (spawn passes a trailing <commit-ish> since #153, so it is
#                  not the last arg). No `worktree remove`, no `show-ref`.
#   remove-noref   clean/reap tests. `worktree remove` deletes the target dir
#                  (the last arg) like real git; `show-ref` exits 1 (branch
#                  absent, so `branch -D` is skipped).
#   remove-ref     as remove-noref but `show-ref` exits 0 (branch present, so
#                  the `branch -D` path is exercised).

install_fake_git() { # <stubbin> [add|remove-noref|remove-ref]
  local stubbin="$1" mode="${2:-add}"
  case "$mode" in
    add)
      cat > "$stubbin/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
if [ "${args[$i]:-}" = "worktree" ] && [ "${args[$((i+1))]:-}" = "add" ]; then
  # first positional after `add` is the path (skip -b/-B <branch> and flags);
  # spawn passes a trailing <commit-ish> since #153, so not the last arg
  j=$((i+2))
  while [ $j -lt ${#args[@]} ]; do
    case "${args[$j]}" in -b|-B) j=$((j+2)) ;; -*) j=$((j+1)) ;; *) break ;; esac
  done
  mkdir -p "${args[$j]}"
fi
exit 0
EOF
      ;;
    remove-noref)
      cat > "$stubbin/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
case "${args[$i]:-}" in
  worktree)
    if [ "${args[$((i+1))]:-}" = "remove" ]; then
      rm -rf "${args[${#args[@]}-1]}"
    fi ;;
  show-ref) exit 1 ;;
esac
exit 0
EOF
      ;;
    remove-ref)
      cat > "$stubbin/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
case "${args[$i]:-}" in
  worktree)
    if [ "${args[$((i+1))]:-}" = "remove" ]; then
      rm -rf "${args[${#args[@]}-1]}"
    fi ;;
  show-ref) exit 0 ;;   # branch present -> exercise branch -D
esac
exit 0
EOF
      ;;
    *)
      echo "install_fake_git: unknown mode '$mode'" >&2
      return 1
      ;;
  esac
  chmod +x "$stubbin/git"
}
