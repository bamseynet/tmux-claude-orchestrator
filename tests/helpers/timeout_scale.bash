# Shared ORCH_TEST_TIMEOUT_SCALE reader (issue #125).
#
# scaled_timeout <base>: prints <base> * ORCH_TEST_TIMEOUT_SCALE (default 1x),
# clamped so a scale of 0 or a non-numeric value can never shrink a bound
# below its base -- an unclamped 0 makes `-lt 0`/`timeout 0`/`seq 1 0` bounds
# unsatisfiable or no-ops, which looks like a passing de-flake but actually
# stops asserting anything.
scaled_timeout() { # <base>
  local base="$1" scale="${ORCH_TEST_TIMEOUT_SCALE:-1}"
  [ "$scale" -ge 1 ] 2>/dev/null || scale=1
  echo $((base * scale))
}
