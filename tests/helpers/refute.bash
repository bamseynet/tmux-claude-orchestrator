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
                # assertion rather than passing vacuously; verified exit 2
                # on the GNU grep CI actually runs (ubuntu-latest) and on
                # busybox grep. A DIRECTORY argument also lands there on GNU
                # grep (exit 2, "Is a directory"), i.e. it fails loudly rather
                # than reading as absent; some other greps (ugrep) exit 1 for
                # one and it reads as absent. No call site passes a directory.
                #
                # Wrong arity (or an empty pattern/path -- typically a typo'd
                # variable that expanded to nothing) is a caller bug, not an
                # absence: it fails rather than passing vacuously, which is the
                # whole point of this file. An empty PATTERN matters as much as
                # an empty path: it matches every line, so it looks like a real
                # failure against a non-empty file but passes silently against
                # an empty one.
  [ "$#" -eq 2 ] || return 2
  [ -n "$1" ] || return 2
  [ -n "$2" ] || return 2
  [ -e "$2" ] || return 0
  local n status=0
  n="$(grep -c -- "$1" "$2")" || status=$?
  [ "$status" -le 1 ] || return 1
  [ "${n:-0}" -eq 0 ]
}

refute_grep_in_existing() { # <pattern> <file> -- same, but ALSO fails if
                            # <file> is missing, so the assertion can't pass
                            # vacuously.
  [ "$#" -eq 2 ] || return 2
  [ -n "$1" ] || return 2
  [ -n "$2" ] || return 2
  [ -e "$2" ] || return 1
  refute_grep "$1" "$2"
}

refute_alive() { # <pid> -- fails if the pid is still running.
                 # Same arity/empty guard as refute_grep, and for the same
                 # reason: `kill -0 ""` fails, so an unset or typo'd pid
                 # variable would otherwise read as "not running" and pass
                 # vacuously forever. A NON-NUMERIC pid is the same hole
                 # (`kill -0 abc` -> "arguments must be process or job IDs",
                 # exit 1, i.e. "not running"), so require digits; the `case`
                 # form is used over `[[ =~ ]]` for bash 3.2 (see the bash32
                 # CI job).
  [ "$#" -eq 1 ] || return 2
  case "$1" in
    '' | *[!0-9]*) return 2 ;;
  esac
  ! kill -0 "$1" 2>/dev/null
}
