#!/usr/bin/env bash
# mutation-scope.sh — the diff a mutation run is allowed to measure, resolved
# once and reported. Read-only: it runs git plumbing and returns facts.
#
# This verb owns the part of mutation testing that was previously resolved
# independently at every call site, which is how the same run got three
# different scopes. It does two things and refuses both to guess:
#
#   1. It resolves the base ref. Not "main", not "the default branch if you
#      cannot resolve it" — the actual integration base of this run, and an
#      explicit error when that cannot be established. A wrong base is not a
#      slightly-wrong diff: it is a diff against a different tree, and every
#      engine here answers a degenerate diff by mutating the WHOLE module while
#      still reporting that it was diff-scoped. That is the single most
#      expensive failure in this check, and it is invisible in the output.
#
#   2. It refuses an empty scope. `ok=false` with MUTATION_SCOPE_EMPTY is the
#      honest answer for "this change touches no source", and it is deliberately
#      not `ok=true` with an empty file list: a caller that only checks `ok` must
#      not be able to read "nothing to mutate" as "mutation testing passed".
#
# The caller still owns the ENGINE and the invocation; the repository's own
# docs (AGENTS.md) say how it mutates. This verb knows nothing about any
# mutation tool; it only knows git, so it stays correct for languages whose
# engines this script has never heard of.

swe_source_once core.sh change/common.sh change/usage.sh

# Resolve the base ref as a commit-ish that EXISTS, or fail. The three
# candidates are spellings of ONE declared name, not three fallbacks: they differ
# only in how the name is written in this tree. There is deliberately no
# "otherwise try main" — a fourth candidate would be a guess, and a guess here
# does not produce a slightly-wrong diff, it produces a diff against a different
# tree.
_msc_resolve_base() { # <name>
  local name=$1 ref
  [[ -n $name ]] || return 1
  for ref in "refs/remotes/origin/$name" "refs/heads/$name" "$name"; do
    if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s' "$ref"
      return 0
    fi
  done
  return 1
}

# The files a caller may mutate, narrowed to those a mutation engine can act on.
# The filter is by extension and is intentionally coarse: it removes lockfiles,
# docs and assets that no engine in the table mutates, and nothing else. Deciding
# which engine exists is not this verb's job.
_msc_mutable_paths() {
  grep -E '\.(go|java|kt|scala|rs|py|js|jsx|ts|tsx|rb|php|cs|swift|mjs|cjs)$'
}

# Whether a base NAME resolves in this tree, in any of its spellings.
_msc_base_exists() {
  local name=$1 ref
  for ref in "refs/remotes/origin/$name" "refs/heads/$name" "$name"; do
    git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 && return 0
  done
  return 1
}

cmd_mutation_scope() {
  local base_arg=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) change_usage ;;
      --base) base_arg=${2:-}; shift 2 || fail "missing_value_for_--base" ;;
      --base=*) base_arg=${1#--base=}; shift ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  need git
  git rev-parse --git-dir >/dev/null 2>&1 || fail "MUTATION_SCOPE_NOT_A_REPO"

  local head
  head=$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
  [[ -n $head ]] || fail "MUTATION_SCOPE_NO_HEAD"

  # Base resolution. All three sources are DECLARATIONS, in decreasing priority,
  # and `base_source` reports which one was used so a surprising scope is
  # explainable instead of merely wrong:
  #
  #   flag        — the caller pinned it
  #   integration — this run's integration base (SWE_INTEGRATION_BASE)
  #   origin_head — the repository's own declaration of its default branch,
  #                 i.e. what `origin/HEAD` points at
  #
  # The integration base is a NAME, and a name that does not resolve in this tree
  # is a configuration error worth surfacing, not something to paper over — which
  # is why it is tried before origin/HEAD and why the failure names it.
  local base_name=$base_arg base_source=flag
  if [[ -z $base_name ]]; then
    base_source=integration
    # The mechanism is read directly instead of through
    # change_resolve_destination, because that helper turns a missing base into
    # a process exit. Here a missing base is an EXPECTED input — it is one of
    # the three sources, and failing on it would skip the other two.
    mech_capture mechanism_destination
    if [[ $MECH_RC -eq 0 ]]; then
      base_name=$(mech_get '.integration_base')
    else
      base_name=''
    fi
  fi
  if [[ -z $base_name ]] || ! _msc_base_exists "$base_name"; then
    if [[ -n $base_arg ]]; then
      base_name=$base_arg
      base_source=flag
    else
      local head_ref=''
      head_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || head_ref=''
      [[ $head_ref == origin/* ]] && head_ref=${head_ref#origin/}
      if [[ -n $head_ref ]] && _msc_base_exists "$head_ref"; then
        base_name=$head_ref
        base_source=origin_head
      else
        fail "MUTATION_BASE_UNRESOLVABLE" \
          "$(jq -nc --arg integration "${base_name:-}" --arg flag "$base_arg" '{
             integration_base: (if $integration == "" then null else $integration end),
             flag_base: (if $flag == "" then null else $flag end),
             searched: ["--base", "SWE_INTEGRATION_BASE", "origin/HEAD"]}')"
      fi
    fi
  fi

  local base_ref
  base_ref=$(_msc_resolve_base "$base_name") || \
    fail "MUTATION_BASE_UNRESOLVABLE" \
      "$(jq -nc --arg base "$base_name" '{base: $base, searched: ["refs/remotes/origin/<base>","refs/heads/<base>","<base>"]}')"

  # `A...B` (three dots), not `A..B`: the diff the reviewer means is "what this
  # change introduced", which is the merge-base diff. Two dots would also report
  # every commit that landed on the base after the branch point.
  local changed=''
  changed=$(git diff --name-only "$base_ref...$head" 2>/dev/null) || changed=''

  local -a all=() mutable=()
  if [[ -n $changed ]]; then
    mapfile -t all <<< "$changed"
    mapfile -t mutable < <(printf '%s\n' "${all[@]}" | _msc_mutable_paths)
  fi

  # An empty scope is a real, common outcome (docs-only, CI-only, config-only)
  # and it must read as "nothing to measure", never as "nothing found wrong".
  if [[ ${#mutable[@]} -eq 0 ]]; then
    fail "MUTATION_SCOPE_EMPTY" \
      "$(jq -nc --arg base "$base_ref" --argjson changed "$(printf '%s\n' "${all[@]:-}" | grep -c . || printf 0)" \
         '{base: $base, changed_files: $changed, mutable_files: 0}')"
  fi

  jq -nc --arg base_name "$base_name" --arg base_source "$base_source" \
         --arg base "$base_ref" --arg head "$head" \
         --argjson changed "$(printf '%s\n' "${all[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')" \
         --argjson files "$(printf '%s\n' "${mutable[@]}" | jq -R . | jq -sc .)" \
         --argjson warnings "$(warnings_json)" '
    {ok: true, base_name: $base_name, base_source: $base_source,
     base: $base, head: $head,
     changed_files: $changed, files: $files,
     file_count: ($files | length), warnings: $warnings}'
  exit 0
}
