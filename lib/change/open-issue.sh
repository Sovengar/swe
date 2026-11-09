#!/usr/bin/env bash
# open-issue.sh — publish the run's approved issue to the project's issue
# tracker, exactly once.
#
# The planning artifacts live outside the repository, so they never reach the
# tracker on their own. This verb is the seam that turns the approved issue into
# a tracked item, and it is idempotent on purpose: a resumed run re-reads the
# marker this verb wrote into the issue file and answers with the existing item
# instead of opening a second one.
#
# The marker is the durable half of the run's memory. The orchestrating agent
# mirrors it into the persisted state topic; this verb never needs that topic to
# stay honest, because the marker travels with the artifact itself.
#
# Contract (shared with every pipeline verb):
#   stdout: exactly one line of JSON, always with an "ok" boolean.
#   exit 0: ok=true. exit 1: ok=false (reason inside the JSON). exit 2: usage.

swe_source_once core.sh change/common.sh

# The line that records the published item inside the issue file. One writer:
# this verb. The planning agent only reads it.
_ISSUE_MARKER='Forge-Issue:'

cmd_open_issue() {
  local issue_file='' plan_file='' title='' dry_run=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --issue-file)
        [[ $# -ge 2 ]] || change_usage
        issue_file=$2; shift 2 ;;
      --plan-file)
        [[ $# -ge 2 ]] || change_usage
        plan_file=$2; shift 2 ;;
      --title)
        [[ $# -ge 2 ]] || change_usage
        title=$2; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      -h|--help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done
  # A missing issue file is a usage error, not a failed publication: there is
  # nothing to publish and nothing to retry.
  [[ -n $issue_file ]] || change_usage

  [[ -f $issue_file ]] || fail "ISSUE_FILE_UNREADABLE" \
    "$(jq -nc --arg path "$issue_file" '{path: $path}')"

  # --- already published? -------------------------------------------------
  # The marker, not the network, is the first answer. A resumed run asks this
  # verb again; asking the tracker would be a second round trip that can still
  # race, while the marker is a local fact.
  local marker='' number='' url='' rest=''
  marker=$(grep -m1 -E "^${_ISSUE_MARKER}" "$issue_file" 2>/dev/null) || marker=''
  if [[ -n $marker ]]; then
    rest=${marker#*:}; rest=${rest# }
    number=${rest%% *}
    if [[ $rest == *" "* ]]; then url=${rest#* }; else url=''; fi
    # A malformed marker is a human edit. Refusing beats opening a duplicate
    # that nobody can tell apart from the real one later.
    [[ $number =~ ^[0-9]+$ ]] || fail "ISSUE_MARKER_INVALID" \
      "$(jq -nc --arg path "$issue_file" '{path: $path}')"
    jq -nc --arg number "$number" --arg url "$url" '
      {ok: true, existing: true, dry_run: false,
       issue: {number: ($number | tonumber),
               url: (if $url == "" then null else $url end)},
       warnings: []}'
    exit 0
  fi

  # --- payload ------------------------------------------------------------
  # The marker line describes the run, not the work, so it never enters the body.
  local body=''
  body=$(grep -v -E "^${_ISSUE_MARKER}" "$issue_file" 2>/dev/null) || body=''

  if [[ -z $title ]]; then
    title=$(printf '%s\n' "$body" | grep -m1 -E '^#+[[:space:]]+' \
            | sed -E 's/^#+[[:space:]]+//') || title=''
    [[ -n $title ]] || title=$(printf '%s\n' "$body" | grep -m1 -E '[^[:space:]]') || title=''
  fi
  # One line, one spacing rule, at most 72 columns: a title that wraps is a
  # title a human rewrites by hand.
  title=$(printf '%s' "$title" | tr '\n\t' '  ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  title=${title:0:72}
  [[ -n $title ]] || fail "ISSUE_TITLE_EMPTY"

  if [[ -n $plan_file ]]; then
    [[ -f $plan_file ]] || fail "ISSUE_PLAN_UNREADABLE" \
      "$(jq -nc --arg path "$plan_file" '{path: $path}')"
    body+=$'\n\n## Plan summary\n\n'
    body+=$(cat "$plan_file")
  fi

  # The state directory is an absolute machine-specific path. It stays out of
  # the published body: the tracker is read elsewhere, by people who do not have
  # this filesystem.
  local planning_dir=''
  planning_dir=$(dirname "$(readlink -f "$issue_file" 2>/dev/null || printf '%s' "$issue_file")")
  body=${body//"$planning_dir"/<planning_dir>}
  if [[ -n $plan_file ]]; then
    body=${body//"$(dirname "$(readlink -f "$plan_file" 2>/dev/null || printf '%s' "$plan_file")")"/<planning_dir>}
  fi

  if [[ $dry_run == true ]]; then
    jq -nc --arg title "$title" --arg body "$body" '
      {ok: true, existing: false, dry_run: true, title: $title, body: $body,
       warnings: []}'
    exit 0
  fi

  # --- publish ------------------------------------------------------------
  local body_file='' rc=0 reason=''
  body_file=$(mktemp) || fail "ISSUE_BODY_FILE_FAILED"
  printf '%s\n' "$body" > "$body_file"
  mech_capture mechanism_open_issue "$title" "$body_file"
  rc=$MECH_RC
  rm -f "$body_file"
  if [[ $rc -ne 0 ]]; then
    reason=$(printf '%s' "$MECH_OUT" | jq -r '.error // empty' 2>/dev/null) || reason=''
    [[ -n $reason ]] || reason='ISSUE_CREATE_FAILED'
    fail "$reason"
  fi

  number=$(mech_get '.number // empty')
  url=$(mech_get '.url // empty')

  # The marker is written HERE, by the verb that created the item, so the next
  # call cannot depend on the agent remembering to record it.
  if [[ -n $number ]]; then
    printf '%s %s %s\n' "$_ISSUE_MARKER" "$number" "$url" >> "$issue_file" \
      || warn+=("issue_marker_write_failed")
  else
    warn+=("issue_number_unknown")
  fi

  jq -nc --argjson number "${number:-null}" --arg url "$url" \
         --argjson warnings "$(warnings_json)" '
    {ok: true, existing: false, dry_run: false,
     issue: {number: (if $number == "" then null else $number end),
             url: (if $url == "" then null else $url end)},
     warnings: $warnings}'
  exit 0
}
