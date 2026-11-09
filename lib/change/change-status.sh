#!/usr/bin/env bash
# change-status.sh — how is my change doing. Read-only: reports the normalized,
# mechanism-agnostic change view for the current repository and change.

swe_source_once core.sh change/common.sh

cmd_change_status() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  change_resolve_destination

  local view='' review='null'
  mech_capture mechanism_change_view
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"
  # Held in a local: the next capture overwrites the shared MECH_OUT slot, and
  # the view is still needed by the jq below.
  view=$MECH_OUT

  # The review loop's position travels with the change view: a caller that knows
  # the state of the change also knows where its review stands, without a second
  # verb and without being told. An unreachable ledger is a warning, never a
  # refusal — the change view itself is still a valid answer.
  mech_capture mechanism_review_state
  if [[ $MECH_RC -eq 0 ]]; then
    review=$(printf '%s' "$MECH_OUT" | jq -c '.ledger // {} | if length == 0 then null else . end')
  else
    warn+=("review_state_unavailable")
  fi

  jq -nc --arg repository "$DEST_REPOSITORY" --arg integration_base "$DEST_BASE" \
         --argjson view "$view" --argjson review "$review" \
         --argjson warnings "$(warnings_json)" '
    ($view | .verification.state =
      (if .verification.state == "none" then "absent" else .verification.state end)) as $v
    | {ok: true, repository: $repository, integration_base: $integration_base}
      + $v + {review: $review, warnings: $warnings}'
  exit 0
}
