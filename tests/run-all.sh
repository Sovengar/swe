#!/usr/bin/env bash
# run-all.sh — run every swe test suite in order and summarize. A suite is
# allowed to SKIP (e.g. lifecycle without `wt`); a skip is reported as such and
# does not fail the run. Any suite that fails makes the whole run fail.
#
# The mutation supervisor used to live in lib/executable_watchdog.sh with its own
# suite. It is vendored into gitdash now (scripts/watchdog.sh + its test); do not
# re-vendor it here.
#
# Run with: bash tests/run-all.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

rc=0
for suite in contract.sh lifecycle.sh change.sh publish-guards.sh; do
  out=$(bash "$HERE/$suite" 2>&1)
  status=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  if printf '%s\n' "$out" | grep -q '^SKIP'; then
    echo "SKIP  $suite"
  elif [[ $status -eq 0 ]]; then
    echo "PASS  $suite"
  else
    echo "FAIL  $suite"
    rc=1
  fi
done

exit "$rc"
