#!/usr/bin/env bash
# swe-pipeline.sh — the PIPELINE axis entrypoint: what state is my change in.
#
# This file owns every change/repository verb — `how-to-test`, `mutation-scope`,
# `await-verification`, `change-status`, `open-issue`, `publish-change`, `record-review`,
# `review-round`, `ready-to-integrate`, `shape-change-history`, `integrate-change`,
# `clean-up-after-integration`. It never creates a working environment: that is
# `ensure` in `isolation.sh`, and nothing here can substitute for it.
#
# Why the split matters: a shared run works in place, on whatever branch the
# session already had. It has no change branch of its own, so there is nothing to
# publish. When both axes shared one entrypoint, a shared run still advertised
# `publish-change` because a forge existed, and `_forge_publish` then tried to
# open a pull request from the integration base into itself (`--base main
# --head main`), which the forge refuses. The opaqueness was the real damage: an
# agent read PUBLISH_FAILED as transient and retried.
#
# Two guards close that hole at the only place that can prove it:
#   CHANGE_BRANCH_IS_BASE   — the current branch IS the integration base.
#   NO_COMMITS_TO_PUBLISH   — the branch exists but carries no commit over the base.
# Both are refusals, not warnings: nothing downstream can make either publishable.
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
  ''|-h|--help|help)
    swe_source_once change/usage.sh
    change_usage
    ;;
esac

module='' fn=''
if [[ -f "$SWE_LIB/change.manifest" ]]; then
  while IFS=$'\t' read -r verb mod func; do
    [[ -n $verb && $verb != \#* ]] || continue
    if [[ $verb == "$cmd" ]]; then module=$mod; fn=$func; break; fi
  done < "$SWE_LIB/change.manifest"
fi

[[ -n $module ]] || fail "unknown_subcommand_$cmd"

shift
swe_source_once "$module"
"$fn" "$@"
