#!/usr/bin/env bash
# core.sh — the shared primitives every other module leans on: the constants,
# the stdout JSON-contract helpers, and the idempotent loader. Sourced directly
# by the entrypoint, never executed on its own.

# Idempotent module loader. A module declares its own dependencies by calling
# `swe_source_once <file>...` as its first executable line, so the entrypoint
# just names the one module a verb needs and the graph resolves itself. Sourcing
# is guarded because re-running a module's top level would wipe the `warn` array
# that the running handler has been filling in.
_SWE_SOURCED=()
swe_source_once() {
  local m
  for m in "$@"; do
    case " ${_SWE_SOURCED[*]-} " in *" $m "*) continue ;; esac
    _SWE_SOURCED+=("$m")
    # shellcheck source=/dev/null
    . "$SWE_LIB/$m"
  done
}

# The type and slug constants are this module's public interface: workspace.sh
# reads them, so their use is invisible from core.sh alone.
# shellcheck disable=SC2034
readonly VALID_TYPES="feature fix refactor chore docs"
# The environment axis (ADR-0005): what the run OWNS. `worktree` requires a
# repository; `shared` does not, and an impossible cell downgrades to `shared`
# with a reason instead of failing. Parallel/stacked branches are not an
# environment: that is a vcs capability (`gitbutler | jj`).
# shellcheck disable=SC2034
readonly VALID_ENVIRONMENTS="worktree shared"
# The planning directory and the git branch do not use the same word: the
# directory says `feature`, the branch says `feat` (see swe.md branch rules).
# shellcheck disable=SC2034
readonly SLUG_RE='^[a-z0-9]+(-[a-z0-9]+)*$'

usage() {
  cat >&2 <<'EOF'
Usage:
  swe ensure --type <feature|fix|refactor|chore|docs> --slug <slug>
                       [--environment <worktree|shared>] [--base <ref>]
  swe location [--expect <dir>]
  swe resolve --branch <branch> [--from-anywhere]
  swe remove --branch <branch> [--working-environment <path>]
                                    [--base <ref>] [--force] [--force-delete]
  swe close --view <view_id>

  This entrypoint owns the ISOLATION axis only. The change/repository verbs
  (publish-change, change-status, integrate-change, ...) belong to
  the pipeline verbs of `swe` and are rejected here.

Contract:
  stdout: exactly one line of JSON, always with an "ok" boolean. Nothing else.
  exit 0: ok=true.  exit 1: ok=false (reason inside the JSON).  exit 2: usage error.
  Progress and tool chatter go to stderr, so a caller can read stdout unfiltered.
EOF
  exit 2
}

# --- json output ------------------------------------------------------------

warn=()

warnings_json() {
  if [[ ${#warn[@]} -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${warn[@]}" | jq -R . | jq -sc .
  fi
}

# Callers pass a JSON object to enrich the failure, so the caller of this script
# gets the context needed to act (which path, which branch, how many commits)
# instead of a bare reason string.
fail() { # fail <reason> [json-object]
  local reason=$1
  local extra=${2-}
  # Note: the default must not be written as ${2:-'{}'}; the quotes survive the
  # expansion and jq then rejects 'not json' instead of printing the failure.
  [[ -n $extra ]] || extra='{}'
  jq -nc --arg reason "$reason" --argjson extra "$extra" \
    '{ok: false, reason: $reason} + $extra + {warnings: []}'
  exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || fail "missing_dependency_$1"; }
