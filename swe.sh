#!/usr/bin/env bash
# swe.sh — the single entrypoint. `swe <verb>` from PATH.
#
# The lifecycle and the change pipeline are two axes, each owned by its own
# file, and this facade never re-implements either:
#   isolation.sh     where the run happens; the only verb that CREATES it (`ensure`)
#   swe-pipeline.sh  the state of a change that already has a branch
#
# The split exists because the two axes have different preconditions. A shared
# run has no change branch of its own, so it must not advertise `publish-change`
# simply because a forge exists; when one file served both axes, such a run tried
# to open a pull request from the integration base into itself.
#
# Each verb is routed by the manifest that owns it. `isolation` wins on a
# collision by construction: the lifecycle names were frozen first, and the
# pipeline manifest is only consulted when the lifecycle one did not match.
#
# Contract: transparent — the executed entrypoint's stdout, stderr and exit code
# are the caller's, so the one-line-JSON contract is unchanged.

set -euo pipefail

SWE_HOME=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
readonly SWE_HOME
SWE_LIB="$SWE_HOME/lib"
readonly SWE_LIB

cmd=${1:-}

owner=''
if [[ -f "$SWE_LIB/verbs.manifest" ]]; then
  while IFS=$'\t' read -r verb _ _; do
    [[ -n $verb && $verb != \#* ]] || continue
    if [[ $verb == "$cmd" ]]; then owner=isolation; break; fi
  done < "$SWE_LIB/verbs.manifest"
fi

if [[ -z $owner && -f "$SWE_LIB/change.manifest" ]]; then
  while IFS=$'\t' read -r verb _ _; do
    [[ -n $verb && $verb != \#* ]] || continue
    if [[ $verb == "$cmd" ]]; then owner=pipeline; break; fi
  done < "$SWE_LIB/change.manifest"
fi

# Help and an empty invocation print the isolation usage, which is the one this
# name has always printed for them.
resolve_entry() { # <name-without-extension>
  local base="$SWE_HOME/$1.sh"
  [[ -f $base ]] || return 1
  printf '%s\n' "$base"
}

case ${owner:-isolation} in
  pipeline)
    entry=$(resolve_entry swe-pipeline) || { printf '{"ok":false,"reason":"MISSING_ENTRYPOINT_swe-pipeline","warnings":[]}\n'; exit 1; }
    ;;
  *)
    entry=$(resolve_entry isolation) || { printf '{"ok":false,"reason":"MISSING_ENTRYPOINT_isolation","warnings":[]}\n'; exit 1; }
    ;;
esac
exec bash "$entry" "$@"
