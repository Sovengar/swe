#!/usr/bin/env bash
# publish-change.sh — make my change available, in the mode the isolation allows.
#
# Two verbs, one intent ("others can see my commit"), two mechanisms:
#
#   publish-change   PUSH. The shared isolation works on the real branch, so the
#                    only publication that exists is `git push`. There is no
#                    pull request to open: the branch already IS the place the
#                    change lands. No `--open`, because a push has no draft.
#   propose-change   PULL REQUEST. The worktree isolation works on a change
#                    branch, so the change is proposed into the integration base
#                    and a review gates it. Idempotent, and `--open` marks it
#                    ready for integration.
#
# The isolation extension chooses which verb the agent is offered; this file
# never guesses the mode. Splitting the verbs is why it does not have to: a
# mode flag would let a prompt pass the wrong one, and the old single verb tried
# `--base main --head main` in shared and reported the forge's refusal as
# PUBLISH_FAILED.

swe_source_once core.sh change/common.sh

# Shared publication: push the current branch.
cmd_publish_change() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) change_usage ;;
      # A push cannot be a draft — there is nothing to open later. Refusing the
      # flag is better than accepting and ignoring it.
      --open) fail "open_not_supported_by_publish_change" ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  # A push has no integration base: it targets the branch's own upstream. Asking
  # the destination resolver here would refuse a valid push whenever the clone
  # does not know the repository's default branch.
  mech_capture mechanism_repository
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)" "$MECH_OUT"
  DEST_REPOSITORY=$(mech_get '.repository')
  DEST_BASE=''

  mech_capture mechanism_push
  # Keep the mechanism's context (branch, upstream, commits ahead) on the
  # failure, so the caller can act instead of reading a bare reason.
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)" "$MECH_OUT"

  jq -nc --arg repository "$DEST_REPOSITORY" --arg integration_base "$DEST_BASE" \
         --argjson published "$MECH_OUT" --argjson warnings "$(warnings_json)" '
    {ok: true, repository: $repository, integration_base: $integration_base}
    + $published + {warnings: $warnings}'
  exit 0
}

# Worktree publication: propose the change branch into the integration base.
cmd_propose_change() {
  local open=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --open)    open=true; shift ;;
      -h|--help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  change_resolve_destination

  mech_capture mechanism_publish "$open"
  # The mechanism object carries the context that makes the refusal actionable
  # (which branch, which base, how many commits). Passing it as the extra object
  # keeps that context on the domain failure instead of leaving a bare reason.
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)" "$MECH_OUT"

  # The gate that would refuse this change at the very END of the run speaks
  # NOW, at publication, while acting on it is still cheap: nothing reports
  # checks for this change and the repository declares no local policy, so the
  # integration gate will fail closed at the close. A warning, never a refusal:
  # the repository may still be configuring its verification.
  if [[ $(mech_get '.verification_state // "unknown"') == none ]] \
     && [[ $(change_verification_policy) != local ]]; then
    warn+=("verification_absent")
  fi

  jq -nc --arg repository "$DEST_REPOSITORY" --arg integration_base "$DEST_BASE" \
         --argjson published "$MECH_OUT" --argjson warnings "$(warnings_json)" '
    {ok: true, repository: $repository, integration_base: $integration_base}
    + $published + {warnings: $warnings}'
  exit 0
}
