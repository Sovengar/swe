#!/usr/bin/env bash
# ready-to-integrate.sh — may this change be integrated right now, and if not,
# why not. Fail-closed: every blocker is surfaced together, in a fixed order, so
# nothing is discovered late at the moment of integrating. It never edits the
# repository; under the `local` verification policy it does run the declared
# suite, because a policy is measured, not assumed.

swe_source_once core.sh change/common.sh

# The blocker vocabulary is domain-level. The order below is the fixed order in
# which blockers are reported.
cmd_ready_to_integrate() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  change_resolve_destination

  # Keep the change view intact: a later mechanism call must not clobber it, or
  # the successful result would report `change: null`.
  local view
  mech_capture mechanism_change_view
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"
  view=$MECH_OUT

  local open requested vstate mode
  open=$(printf '%s' "$view" | jq -r '.open_for_integration')
  requested=$(printf '%s' "$view" | jq -r '.requested_changes')
  vstate=$(printf '%s' "$view" | jq -r '.verification.state')
  if [[ $vstate == none ]]; then vstate=absent; fi

  mech_capture mechanism_integration_mode
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"
  mode=$(mech_get '.mode')

  # Readiness is fail-closed: only `passing` verification is a green light —
  # or, under the repository's own `local` policy, a suite that is green RIGHT
  # NOW. The policy is a proof, not a waiver: it is measured here, so a
  # readiness answer stays true even when nothing hosted ever reports.
  local -a blockers=()
  [[ $open == true ]] || blockers+=(not_open_for_integration)
  if [[ $requested == true ]]; then blockers+=(requested_changes); fi
  if [[ $vstate != passing ]]; then
    case $vstate in
      failing) blockers+=(verification_failing) ;;
      pending) blockers+=(verification_pending) ;;
      *)
        if [[ $(change_verification_policy) == local ]]; then
          case $(change_verify_local) in
            pass) : ;;  # the local suite IS this repository's verification
            fail) blockers+=(verification_failing) ;;
            *)    blockers+=(verification_absent) ;;
          esac
        else
          blockers+=(verification_absent)
        fi ;;
    esac
  fi
  [[ $mode == linear ]] || blockers+=(integration_mode_not_linear)

  if ((${#blockers[@]} > 0)); then
    local blockers_json
    blockers_json=$(printf '%s\n' "${blockers[@]}" | jq -R . | jq -sc .)
    fail "NOT_READY_TO_INTEGRATE" \
      "$(jq -nc --argjson blockers "$blockers_json" \
           '{blockers: $blockers, repository: $repository, integration_base: $base}' \
           --arg repository "$DEST_REPOSITORY" --arg base "$DEST_BASE")"
  fi

  jq -nc --arg repository "$DEST_REPOSITORY" --arg integration_base "$DEST_BASE" \
         --arg change "$(printf '%s' "$view" | jq -r '.change')" \
         --argjson warnings "$(warnings_json)" '
    {ok: true, ready: true, repository: $repository,
     integration_base: $integration_base, change: $change,
     warnings: $warnings}'
  exit 0
}
