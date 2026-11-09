#!/usr/bin/env bash
# mechanism.sh — the internal seam the change/repository verbs are written
# against. The domain layer only ever speaks of a destination, a published
# change, a change view, readiness facts, a history shape and an integration;
# it never names a tool or a mechanism.
#
# Exactly ONE implementation is registered today. Selection is a lookup, not a
# probe chain: the default implementation ships with the shell, and an explicit
# override is honoured only when set (used by the test suite to inject facts).
# Alternative mechanisms (other forges, other VCS, on-disk) are future work and
# are deliberately not implemented.

swe_source_once core.sh

if [[ -n ${SWE_CHANGE_MECHANISM:-} ]]; then
  # Test/command-injection seam: one implementation, injected explicitly.
  # shellcheck source=/dev/null
  . "$SWE_CHANGE_MECHANISM"
else
  swe_source_once change/mechanism/git-forge.sh
fi
