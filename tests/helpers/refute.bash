# Shared absence-assertion helpers (issue #134).
#
# A `!`-negated command is exempt from `set -e`, so a bare `! grep -q ...` /
# `! kill -0 ...` mid-test (i.e. not the last statement of the @test body)
# asserts nothing -- bash swallows its failure and the test sails on.
# Verified against bats-core 1.10.0 and 1.11.0. Use these instead: each
# returns a plain non-zero status, which bats does catch.
#
# refute_alive's `!` is safe: the exemption applies at the call site, and
# `refute_alive "$pid"` at the call site is a plain command, not itself
# `!`-negated.

refute_grep() { # <pattern> <file> -- fails if <pattern> is present.
                # A missing <file> counts as absent (deliberate), handled by
                # the explicit -e test. Every OTHER grep error (exit >= 2 --
                # e.g. an invalid regex, or an unreadable file) fails the
                # assertion rather than passing vacuously. Verified exit 2 on
                # GNU grep, busybox grep and ugrep. Note a DIRECTORY argument
                # is not in that set: all three exit 1 ("no match") for one,
                # so it still reads as absent.
  [ -e "$2" ] || return 0
  local n status=0
  n="$(grep -c -- "$1" "$2")" || status=$?
  [ "$status" -le 1 ] || return 1
  [ "${n:-0}" -eq 0 ]
}

refute_grep_in_existing() { # <pattern> <file> -- same, but ALSO fails if
                            # <file> is missing, so the assertion can't pass
                            # vacuously.
  [ -e "$2" ] || return 1
  refute_grep "$1" "$2"
}

refute_alive() { # <pid> -- fails if the pid is still running.
  ! kill -0 "$1" 2>/dev/null
}
