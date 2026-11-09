#!/usr/bin/env bash
# session.sh — the location contract: where the session is, and the run's paths
# fetched from inside the run's working environment. The two are one unit:
# `resolve` is the gate and `location` is how the caller proves it passed.

swe_source_once core.sh git.sh identity.sh

# --- session location -------------------------------------------------------

# Where the session lives right now, and whether it is where the caller expects.
#
# No harness API is involved and none is needed: every harness runs its shell
# with cwd = the session directory, so `pwd -P` IS the session location. That is
# what makes this check portable across opencode, codex and pi.
#
# A mismatch is not a failure — it is the expected state right after `ensure`,
# before the orchestrator has relocated. So the exit stays 0 and `match` carries
# the answer; a caller that wants the run to stop must act on `match:false`.
cmd_location() {
  local expect=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --expect) expect=${2:-}; shift 2 ;;
      -h|--help) usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  local here harness git=false forge=false
  here=$(pwd -P)
  harness=$(harness_id)
  # Git is optional: the location contract names it, so a caller never has to
  # guess from a failed ensure. `forge` is a repository WITH a remote.
  if in_git_repository; then
    git=true
    local remote
    remote=$(git remote 2>/dev/null) || remote=''
    [[ -n $remote ]] && forge=true
  fi

  if [[ -z $expect ]]; then
    jq -nc --arg session_dir "$here" --arg harness "$harness" \
      --argjson git "$git" --argjson forge "$forge" \
      '{ok: true, session_dir: $session_dir, harness: $harness,
        git: $git, forge: $forge}'
    exit 0
  fi

  # Normalize so symlinked paths and trailing slashes do not read as a mismatch.
  local want
  want=$(cd "$expect" 2>/dev/null && pwd -P) \
    || fail "expect_not_a_directory" "$(jq -nc --arg d "$expect" '{expected: $d}')"

  local match=false
  [[ $here == "$want" ]] && match=true

  jq -nc --arg session_dir "$here" --arg expected "$want" \
         --arg harness "$harness" --argjson match "$match" \
         --argjson git "$git" --argjson forge "$forge" \
    '{ok: true, match: $match, session_dir: $session_dir,
      expected: $expected, harness: $harness, git: $git, forge: $forge}'
  exit 0
}

# --- resolve ----------------------------------------------------------------

# The run's paths, obtainable ONLY from inside the run's working environment.
#
# This is the deterministic half of the location contract. A child session is
# born wherever its parent lives, so a child launched before the orchestrator
# relocated would otherwise work in the primary checkout — silently, on the
# wrong branch. `resolve` takes that possibility away from the wrong side of the
# fence: the child does not RECEIVE workingEnvironment/planning_dir, it FETCHES
# them, and from the wrong directory there is nothing to fetch. A child that skips
# this step has no paths and cannot act at all, which is a failure that cannot be
# mistaken for success — unlike a child that merely forgets to check.
#
# It needs no harness API, so the same gate protects opencode, codex and pi.
#
# --from-anywhere is the one named exception: the closer, which runs AFTER the
# orchestrator left the working environment (it is the agent that destroys it)
# and therefore cannot be inside. Every other agent is inside by construction.
cmd_resolve() {
  local branch='' from_anywhere=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --branch)        branch=${2:-}; shift 2 ;;
      --from-anywhere) from_anywhere=true; shift ;;
      -h|--help)       usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done
  [[ -n $branch ]] || fail "missing_--branch"
  need git

  in_git_repository || fail "not_a_git_repository"

  # The branch carries the whole run identity: `<prefix>/<slug>`. Anything that
  # does not decompose that way was not created by ensure, so refuse rather than
  # guess which run it is supposed to be.
  local prefix=${branch%%/*} slug=${branch#*/} type=''
  [[ $prefix != "$branch" && -n $slug ]] || fail "invalid_branch_$branch"
  type=$(type_from_prefix "$prefix") || fail "invalid_branch_$branch"

  local we
  we=$(working_environment_for_branch "$branch" || true)
  [[ -n $we ]] || fail "no_working_environment_for_branch" \
    "$(jq -nc --arg b "$branch" '{branch: $b}')"

  # Normalize before comparing: a symlinked checkout must not read as a
  # mismatch, because a gate that misfires is worse than no gate — it would
  # block a correctly-placed child.
  local we_real
  we_real=$(cd "$we" 2>/dev/null && pwd -P) || we_real=$we

  local here
  here=$(pwd -P)
  if [[ $from_anywhere != true && $here != "$we_real" ]]; then
    fail "wrong_location" \
      "$(jq -nc --arg w "$we_real" --arg s "$here" \
          '{expected: $w, session_dir: $s, move_to: $w,
            hint: "this run is worked from inside its working environment; relocate the session there and call resolve again"}')"
  fi

  local planning_dir
  planning_dir=$(planning_dir_for "$we_real" "$type" "$slug")

  jq -nc --arg branch "$branch" --arg workingEnvironment "$we_real" \
         --arg planning_dir "$planning_dir" --arg harness "$(harness_id)" \
         --argjson from_anywhere "$from_anywhere" \
    '{ok: true, branch: $branch, workingEnvironment: $workingEnvironment,
      planning_dir: $planning_dir, harness: $harness,
      from_anywhere: $from_anywhere}'
  exit 0
}
