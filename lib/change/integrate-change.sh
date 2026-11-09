#!/usr/bin/env bash
# integrate-change.sh — integrate my change into its base, respecting the
# repository's integration policy and never bypassing protection or required
# verification. Every aborting check (non-linear mode, collapse, base
# compatibility) happens BEFORE re-publishing, so a computed conflict or a
# not-yet-computed compatibility never touches the remote; verification and
# endorsements are re-read AFTER, against the exact published version. A
# non-atomic failure reports an explicit recovery object.

swe_source_once core.sh change/common.sh

# Closing the tracked item is the LAST and least essential step: the change is
# integrated either way, so a tracker that refuses becomes a warning instead of a
# failed integration the caller would retry for nothing. It is skipped when the
# run never opened an item, and it is safe to repeat: closing twice is a no-op.
_close_issue_if_any() { # <issue-number|"">
  local issue=$1
  [[ -n $issue ]] || return 0
  mech_capture mechanism_close_issue "$issue"
  [[ $MECH_RC -eq 0 ]] || warn+=("issue_not_closed")
  return 0
}

cmd_integrate_change() {
  local issue='' issue_file=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --issue) [[ $# -ge 2 ]] || change_usage; issue=$2; shift 2 ;;
      --issue-file)
                 [[ $# -ge 2 ]] || change_usage; issue_file=$2; shift 2 ;;
      -h|--help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  # The tracked item this change closes, resolved exactly like publication
  # resolves it: an explicit number, or the marker the opening verb wrote.
  local raw_issue=$issue issue_rc=0
  issue=$(change_issue_number "$issue" "$issue_file") || issue_rc=$?
  case $issue_rc in
    0) ;;
    2) fail "issue_file_unreadable" "$(jq -nc --arg path "$issue_file" '{path: $path}')" ;;
    *) fail "invalid_issue_number" "$(jq -nc --arg issue "$raw_issue" '{issue: $issue}')" ;;
  esac

  change_resolve_destination

  # 1. Policy first: refuse a non-linear mode and a collapsing repository before
  #    touching anything.
  mech_capture mechanism_integration_mode
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"
  local mode
  mode=$(mech_get '.mode')
  if [[ $mode != linear ]]; then
    fail "INTEGRATION_MODE_UNSUPPORTED" \
      "$(jq -nc --arg mode "$mode" '{mode: $mode, repository: $repository, integration_base: $base}' \
           --arg repository "$DEST_REPOSITORY" --arg base "$DEST_BASE")"
  fi

  mech_capture mechanism_history_collapses
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"
  if [[ $(mech_get '.collapses') == true ]]; then fail "HISTORY_WOULD_BE_COLLAPSED"; fi

  # 2. Compatibility with the base, still BEFORE re-publishing: an abort here
  #    leaves the remote untouched. A computed conflict needs a human; a state
  #    the forge has not computed yet is transient and must never be reported as
  #    a conflict.
  mech_capture mechanism_integration_compatibility
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"
  local compatibility
  compatibility=$(mech_get '.compatibility')
  if [[ $compatibility == conflict ]]; then
    fail "INTEGRATION_CONFLICT" \
      "$(jq -nc --arg repository "$DEST_REPOSITORY" --arg base "$DEST_BASE" \
           '{repository: $repository, integration_base: $base,
             integration_blocker: "conflict",
             recovery: {change_republished: false, integrated: false,
                        retryable: false, requires_human: true}}')"
  fi
  if [[ $compatibility != ready ]]; then
    fail "INTEGRATION_FAILED" \
      "$(jq -nc '{integration_blocker: "pending",
                  recovery: {change_republished: false, integrated: false,
                             retryable: true}}')"
  fi

  # 3. Re-publish the final shape, then re-read verification and endorsements
  #    against that published version.
  local head
  mech_capture mechanism_history_state
  head=$(mech_get '.head')
  if [[ $head == null ]]; then head=''; fi
  mech_capture mechanism_republish "$head"
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"

  mech_capture mechanism_change_view
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"

  local state change requested vstate endorsements
  change=$(mech_get '.change')
  state=$(mech_get '.state')
  if [[ $state == integrated ]]; then
    # The item is closed even on this re-entry: a run that integrated and then
    # died before closing must end consistent, and closing twice is a no-op.
    _close_issue_if_any "$issue"
    jq -nc --arg repository "$DEST_REPOSITORY" --arg integration_base "$DEST_BASE" \
           --arg change "$change" --argjson warnings "$(warnings_json)" '
      {ok: true, integrated: true, noop: true, repository: $repository,
       integration_base: $integration_base, change: $change, warnings: $warnings}'
    exit 0
  fi

  requested=$(mech_get '.requested_changes')
  endorsements=$(mech_get '.endorsements')
  vstate=$(mech_get '.verification.state')
  if [[ $vstate == none ]]; then vstate=absent; fi

  if [[ $requested == true ]]; then
    fail "ENDORSEMENTS_WITHDRAWN" \
      "$(jq -nc --argjson endorsements "$endorsements" --arg change "$change" \
           '{endorsements: $endorsements, change: $change}')"
  fi
  # Absent verification is decided by the repository's own declaration, and
  # `local` is a proof rather than a waiver: the suite runs HERE, against the
  # exact tree that is about to be integrated (after the sync above), so the
  # green this gate releases is fresh — not the one an earlier gate measured.
  if [[ $vstate == absent && $(change_verification_policy) == local ]]; then
    case $(change_verify_local) in
      pass) vstate=passing ;;
      fail) vstate=failing ;;
      *)    fail "VERIFICATION_UNKNOWN" \
              "$(jq -nc '{verification: {state: "absent",
                                         detail: "local_policy_undetectable"}}')" ;;
    esac
  fi
  [[ $vstate == passing ]] || fail "VERIFICATION_FAILED" \
    "$(jq -nc --arg state "$vstate" --arg change "$change" \
         '{verification: {state: $state}, change: $change}')"

  # 4. Integrate pinned to the verified revision.
  mech_capture mechanism_integrate "$head"
  if [[ $MECH_RC -eq 0 ]]; then
    _close_issue_if_any "$issue"
    jq -nc --arg repository "$DEST_REPOSITORY" --arg integration_base "$DEST_BASE" \
           --arg change "$change" --argjson warnings "$(warnings_json)" '
      {ok: true, integrated: true, noop: false, repository: $repository,
       integration_base: $integration_base, change: $change, warnings: $warnings}'
    exit 0
  fi

  case $(mech_error) in
    # A conflict does not resolve itself: it is not retryable and needs a human.
    conflict)
      fail "INTEGRATION_CONFLICT" \
        "$(jq -nc --arg repository "$DEST_REPOSITORY" --arg base "$DEST_BASE" \
             --arg change "$change" \
             '{repository: $repository, integration_base: $base, change: $change,
               integration_blocker: "conflict",
               recovery: {change_republished: true, integrated: false,
                          retryable: false, requires_human: true}}')"
      ;;
    # The forge has not computed compatibility yet: retryable, never a human call.
    pending)
      fail "INTEGRATION_FAILED" \
        "$(jq -nc --arg change "$change" \
             '{change: $change, integration_blocker: "pending",
               recovery: {change_republished: true, integrated: false,
                          retryable: true}}')"
      ;;
    # A transient failure after re-publishing: retryable, nothing half-applied.
    *)
      fail "INTEGRATION_FAILED" \
        "$(jq -nc --arg change "$change" \
             '{change: $change,
               recovery: {change_republished: true, verified: true,
                          integrated: false, retryable: true}}')"
      ;;
  esac
}
