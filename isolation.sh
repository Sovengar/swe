#!/usr/bin/env bash
# isolation.sh — the ISOLATION axis entrypoint: where a run happens.
#
# This file owns the lifecycle verbs only — `ensure`, `location`, `resolve`,
# `remove`, `close`. It knows nothing about publishing, reviewing or integrating
# a change: those are pipeline verbs and live in `swe-pipeline.sh`.
#
# The split is not cosmetic. A verb belongs to the axis that can satisfy its
# precondition:
#   - isolation.sh answers "is there a working environment, and which one?" and
#     is the only entrypoint that CREATES one (`ensure`).
#   - swe-pipeline.sh answers "what is the state of my change?" and assumes the
#     environment already exists.
# Keeping them in one file let a shared run advertise `publish-change` simply
# because a forge existed, then fail with PUBLISH_FAILED when it tried to open
# a pull request from the integration base into itself. Capability now follows
# the axis: no isolation-created branch, no change verbs.
#
# Entries in `lib/verbs.manifest` are the only verbs routed here. A pipeline verb
# is rejected as unknown instead of being silently handled.
#
# Contract (unchanged from the old facade):
#   stdout: exactly one line of JSON, always with an "ok" boolean. Nothing else.
#   exit 0: ok=true.  exit 1: ok=false (reason inside the JSON).  exit 2: usage error.

set -euo pipefail

SWE_HOME=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
readonly SWE_HOME
SWE_LIB="$SWE_HOME/lib"
readonly SWE_LIB

# shellcheck source=lib/core.sh
. "$SWE_LIB/core.sh"
_SWE_SOURCED=(core.sh)

cmd=${1:-}
case $cmd in
  ''|-h|--help|help) usage ;;
esac

module='' fn=''
while IFS=$'\t' read -r verb mod func; do
  [[ -n $verb && $verb != \#* ]] || continue
  if [[ $verb == "$cmd" ]]; then module=$mod; fn=$func; break; fi
done < "$SWE_LIB/verbs.manifest"

[[ -n $module ]] || fail "unknown_subcommand_$cmd"

shift
swe_source_once "$module"
"$fn" "$@"
