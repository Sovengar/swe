#!/usr/bin/env bash
# shape-change-history.sh — give my change's history its final shape. `plan` is
# the pure, branch-free preview; `apply` is the mutation. The grouping is by
# concern and driven by a repository-declared shape policy (history.sh); this
# module reads the policy, drives the grouping, and enforces the guarantees.

swe_source_once core.sh change/common.sh change/history.sh

cmd_shape_change_history() {
  local sub=${1:-}
  case $sub in
    plan)        shift; _shape_plan "$@" ;;
    apply)       shift; _shape_apply "$@" ;;
    -h|--help)   change_usage ;;
    '')          fail "missing_subcommand" ;;
    *)           fail "unknown_argument_$1" ;;
  esac
}

# Reads and validates the history state; on success the captured MECH_OUT is the
# state object. Fails with the shape-verb reasons when the change cannot be
# shaped at all.
_shape_read_state() {
  mech_capture mechanism_history_state
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"
  if [[ $(mech_get '.unsaved') == true ]]; then fail "UNSAVED_CHANGES"; fi
  if [[ $(mech_get '.protected') == true ]]; then fail "INTEGRATION_BASE_PROTECTED"; fi
}

# The shape policy is a repository-level declaration, read from `.change-shape`.
# It is resolved against the repository, not the caller's cwd: the declaration is
# looked up walking up from where the verb runs, so running from a subdirectory
# does not silently ignore it. It speaks only in domain terms:
#   one-per-concern   (documented default)   single-unit   max:<N>
# A repository that declares nothing gets the default. Sets POLICY_NAME,
# POLICY_LIMIT (0 = none) and POLICY_DEFAULT.
_shape_read_policy() {
  POLICY_NAME=one-per-concern
  POLICY_LIMIT=0
  POLICY_DEFAULT=true

  local dir=$PWD f=''
  while :; do
    if [[ -f "$dir/.change-shape" ]]; then f="$dir/.change-shape"; break; fi
    [[ $dir == / ]] && break
    dir=$(dirname "$dir")
  done
  [[ -n $f ]] || return 0

  local line
  line=$(awk 'NF && $1 !~ /^#/ {print $1; exit}' "$f")
  [[ -n $line ]] || return 0

  POLICY_DEFAULT=false
  case $line in
    one-per-concern) POLICY_NAME=one-per-concern ;;
    single-unit)     POLICY_NAME=single-unit ;;
    max:*)
      local n=${line#max:}
      [[ $n =~ ^[1-9][0-9]*$ ]] || fail "invalid_shape_policy" \
        "$(jq -nc --arg p "$line" '{policy: $p}')"
      POLICY_NAME=max; POLICY_LIMIT=$n ;;
    *) fail "invalid_shape_policy" "$(jq -nc --arg p "$line" '{policy: $p}')" ;;
  esac
}

_shape_steps_tsv() { jq -r '.[] | [.type, .scope] | @tsv'; }

# The concerns present, in first-appearance order.
_shape_concerns_json() { jq -c '[.[].scope] | reduce .[] as $s ([]; if index($s) then . else . + [$s] end)'; }

# Turns the grouping TSV (history_units, on stdin) plus the step subjects into
# the public unit list.
_shape_units_json() { # <steps-json>  (reads grouping TSV on stdin)
  jq -R -s --argjson steps "$1" '
    split("\n") | map(select(length>0)) |
    map(split("\t") as $f |
        {members: ($f[0]|split(" ")|map(tonumber)), type: $f[1], scope: $f[2],
         concerns: (if $f[3] == "" then [] else ($f[3]|split(" ")) end)}) |
    map({type: .type, scope: .scope, members: .members, concerns: .concerns,
         steps: [.members[] as $i | $steps[$i].subject]})'
}

# The auditable evidence of the chosen shape.
_shape_evidence_json() { # <units-json> <concerns-json>
  jq -nc --argjson units "$1" --argjson concerns "$2" \
     --arg policy "$POLICY_NAME" --argjson limit "$POLICY_LIMIT" \
     --argjson from_default "$POLICY_DEFAULT" '
    ($units|length) as $nu | ($concerns|length) as $nc |
    {concerns_detected: $nc, units: $nu, collapsed: ($nu < $nc),
     policy: {name: $policy, limit: (if $limit == 0 then null else $limit end),
              from_default: $from_default},
     reason: (if $policy == "single-unit" then "single-unit policy"
              elif ($policy == "max" and $nu < $nc)
                then "capped by policy at \($limit) unit(s)"
              elif $from_default then "one unit per concern (default policy)"
              else "one unit per concern" end),
     folded: [$units[] | select((.concerns|length) > 1)
              | {unit_scope: .scope, folded_concerns: (.concerns[1:])}]}'
}

_shape_plan() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  _shape_read_state
  _shape_read_policy
  local steps_json tsv units_json concerns already evidence
  steps_json=$(mech_get '.steps')
  concerns=$(printf '%s' "$steps_json" | _shape_concerns_json)
  tsv=$(printf '%s' "$steps_json" | _shape_steps_tsv)
  units_json=$(printf '%s' "$tsv" | history_units "$POLICY_NAME" "$POLICY_LIMIT" \
    | _shape_units_json "$steps_json")
  evidence=$(_shape_evidence_json "$units_json" "$concerns")
  already=$(printf '%s' "$units_json" | jq 'length == 0 or all(.[]; (.members|length)==1)')

  jq -nc --argjson units "$units_json" --argjson concerns "$concerns" \
         --argjson evidence "$evidence" --argjson already "$already" \
         --argjson warnings "$(warnings_json)" '
    {ok: true, units: $units, concerns: $concerns, evidence: $evidence,
     already_shaped: $already,
     message_contract: {format: "<type>(<scope>): <description>",
                        max_subject_length: 72, one_message_per_group: true},
     warnings: $warnings}'
  exit 0
}

_shape_apply() {
  local messages_file=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --messages) messages_file=${2:-}; shift 2 ;;
      -h|--help)  change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done
  [[ -n $messages_file ]] || fail "missing_--messages"
  [[ -f $messages_file ]] || fail "messages_file_not_found" \
    "$(jq -nc --arg f "$messages_file" '{messages_file: $f}')"

  _shape_read_state
  _shape_read_policy
  local steps_json base head_before tsv units_json
  steps_json=$(mech_get '.steps')
  base=$(mech_get '.base')
  head_before=$(mech_get '.head')
  tsv=$(printf '%s' "$steps_json" | _shape_steps_tsv)
  units_json=$(printf '%s' "$tsv" | history_units "$POLICY_NAME" "$POLICY_LIMIT" \
    | _shape_units_json "$steps_json")

  local n_steps n_units
  n_steps=$(printf '%s' "$steps_json" | jq 'length')
  n_units=$(printf '%s' "$units_json" | jq 'length')

  # Already in the planned shape: a true no-op, reported as such.
  if [[ $n_steps -eq $n_units ]]; then
    fail "HISTORY_ALREADY_SHAPED" \
      "$(jq -nc --argjson units "$n_units" '{already_shaped: true, units: $units}')"
  fi

  local -a msgs=()
  mapfile -t msgs < "$messages_file"
  [[ ${#msgs[@]} -eq $n_units ]] || fail "message_count_mismatch" \
    "$(jq -nc --argjson expected "$n_units" --argjson got "${#msgs[@]}" \
         '{expected_messages: $expected, got_messages: $got}')"

  local msgs_json plan_json
  msgs_json=$(printf '%s\n' "${msgs[@]}" | jq -R . | jq -sc .)
  plan_json=$(printf '%s' "$units_json" | jq -c --arg base "$base" --argjson msgs "$msgs_json" '
    {base: $base,
     groups: [range(0; length) as $i | .[$i] + {message: $msgs[$i]}]}')

  local tree_before
  tree_before=$(mechanism_content_tree "$head_before") || fail "HISTORY_REWRITE_FAILED"

  # Explicit rollback: the mechanism resets for its own rebase failure, but any
  # other failure path must be restored here too.
  mech_capture mechanism_history_rewrite "$plan_json"
  if [[ $MECH_RC -ne 0 ]]; then
    mechanism_history_reset "$head_before"
    fail "$(mech_error)"
  fi

  local newhead tree_after
  newhead=$(mech_get '.head')
  tree_after=$(mechanism_content_tree "$newhead") || tree_after=''

  # Content invariant: the resulting content is identical, not a count and not
  # an identifier. A mismatch is rolled back to the pre-shaping state.
  if [[ -z $tree_after || $tree_after != "$tree_before" ]]; then
    mechanism_history_reset "$head_before"
    fail "HISTORY_REWRITE_CHANGED_CONTENT" \
      "$(jq -nc --arg before "$tree_before" --arg after "$tree_after" \
           '{expected_content: $before, resulting_content: $after}')"
  fi

  jq -nc --argjson units "$n_units" --arg policy "$POLICY_NAME" \
         --argjson warnings "$(warnings_json)" \
    '{ok: true, shaped: true, already_shaped: false, units: $units,
      policy: $policy, warnings: $warnings}'
  exit 0
}
