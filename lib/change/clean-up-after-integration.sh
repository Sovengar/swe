#!/usr/bin/env bash
# clean-up-after-integration.sh — tidy up the local leftovers of an integrated
# change. Best-effort by design: failures are demoted to `risks`, never to
# `status`. The single exception is a session still inside the workspace being
# destroyed, which is not a cosmetic failure and is surfaced as a hard refusal.
#
# The change to clean up is named with `--change`: it is the run's identity, the
# same token `resolve` hands back. It is NOT derived from the caller's cwd,
# because the caller is the closer — the one agent forbidden from being inside
# the workspace it is about to destroy — so what it stands on names something
# else entirely. The domain layer says "change" and stays silent on what that
# token resolves to; the mechanism knows.
#
# The mechanism is still not the caller's business: given the change, the script
# finds the checkout, refuses a dirty or a foreign one, and verifies the path is
# gone before reporting it released.

swe_source_once core.sh change/common.sh

cmd_clean_up_after_integration() {
  local change=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --change)   change=${2:-}; shift 2 ;;
      -h|--help)  change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  [[ -n $change ]] || fail "missing_--change" \
    "$(jq -nc '{hint: "name the change to clean up: the caller cannot be inside it, so it has no identity of its own to fall back on"}')"

  mech_capture mechanism_cleanup "$change"

  # A cleanup that could not even be attempted is still not fatal: it becomes a
  # risk and the run stays successful.
  if [[ $MECH_RC -ne 0 ]]; then
    jq -nc --argjson warnings "$(warnings_json)" \
      '{ok: true, cleaned: [], risks: ["cleanup_failed"], warnings: $warnings}'
    exit 0
  fi

  # The session-inside-workspace refusal is the one non-best-effort outcome: the
  # caller's own shell would be left with a dead cwd.
  if [[ $(mech_get '.session_inside_working_environment // empty') != '' ]]; then
    local move_to
    move_to=$(mech_get '.session_inside_working_environment.move_to')
    fail "session_inside_working_environment" \
      "$(jq -nc --arg move_to "$move_to" '{move_to: $move_to}')"
  fi

  jq -nc --argjson cleaned "$(mech_get '.cleaned')" \
         --argjson risks "$(mech_get '.risks')" \
         --argjson warnings "$(warnings_json)" \
    '{ok: true, cleaned: $cleaned, risks: $risks, warnings: $warnings}'
  exit 0
}
