# Shared fake-git fixture (issue #180).
#
# One parameterised `git` PATH stub instead of the same heredoc copy-pasted
# into 17 bats files. Load per-file, like fake-tmux.bash:
#
#   # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
#   source "$BATS_TEST_DIRNAME/helpers/fake-git.bash"
#   install_fake_git "$STUBBIN" [mode]
#
# Every mode exits 0 for anything it does not emulate; the remove-* modes parse
# an optional leading `-C <dir>` once (offset i=2). The mode is an explicit
# argument, not auto-detected, so a test's reliance on `worktree remove`
# deleting a dir stays visible at the call site.
#
#   add (default)  spawn tests. Everything succeeds and nothing is created:
#                  `worktree add` does NOT mkdir its path. spawn.sh creates the
#                  worktree dir itself (`mkdir -p "$wdir/.claude"`) and nothing
#                  between `worktree add` and that line reads the dir (the owner
#                  stamp is a no-op under a fake git either way); the stub's old
#                  mkdir survived mutation across every consumer, so it was dead.
#   remove-noref   clean/reap tests. `worktree remove` deletes the target dir
#                  (the last arg) like real git; `show-ref` exits 1 (branch
#                  absent, so `branch -D` is skipped).
#   remove-ref     as remove-noref but `show-ref` exits 0 (branch present, so
#                  the `branch -D` path is exercised).

install_fake_git() { # <stubbin> [add|remove-noref|remove-ref]
  local stubbin="$1" mode="${2:-add}"
  case "$mode" in
    add)
      printf '#!/usr/bin/env bash\nexit 0\n' > "$stubbin/git"
      ;;
    remove-noref|remove-ref)
      # show-ref exit code: noref -> 1 (skip branch -D), ref -> 0 (exercise it)
      local sr=1
      [ "$mode" = remove-ref ] && sr=0
      cat > "$stubbin/git" <<STUB
#!/usr/bin/env bash
args=("\$@"); i=0
[ "\${args[0]:-}" = "-C" ] && i=2
case "\${args[\$i]:-}" in
  worktree)
    if [ "\${args[\$((i+1))]:-}" = "remove" ]; then
      rm -rf "\${args[\${#args[@]}-1]}"
    fi ;;
  show-ref) exit $sr ;;
esac
exit 0
STUB
      ;;
    *)
      echo "install_fake_git: unknown mode '$mode'" >&2
      return 1
      ;;
  esac
  chmod +x "$stubbin/git"
}
