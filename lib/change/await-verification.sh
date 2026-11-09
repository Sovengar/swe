#!/usr/bin/env bash
# await-verification.sh — the verification state of the change on the current
# line of work, read through the entrypoint like every other change verb.
#
# It exists because the pipeline already had a word for "the verification has not
# finished" and nothing to DO about it. `ready-to-integrate` maps `pending` to a
# blocker and `integrate-change` maps it to a retryable failure, which is right
# for an orchestrator: it comes back later. It is wrong for an agent, because the
# agent cannot come back later — it has no `question` permission and a Relay
# Contract with no clock. So a closer that meets `pending` can only re-run the
# same integrate (which cannot change anything, the verification is still
# running) or report a retryable failure it has no way to act on.
#
#   --watch   block until nothing is pending, bounded by a deadline
#
# The default is a single read. That asymmetry is deliberate and matches how the
# rest of the pipeline is built: readiness is computed from an instant, and
# blocking is something a caller opts into with a deadline it chose. Making the
# wait the default would turn every verification question into an open-ended hold
# in an agent that cannot ask anyone what the deadline should be.
#
# What this verb must never do is answer a DIFFERENT question than the readiness
# gate. That is why it speaks the same vocabulary (`none|passing|failing|
# pending`) the change view already publishes, and why `ok` is not a verdict: `ok`
# says the question was answered, `verification.state` says the answer. A caller
# that only reads `ok` learns nothing about the verification, which is the safe
# direction to be wrong in.

swe_source_once core.sh change/common.sh change/usage.sh change/mechanism.sh

cmd_await_verification() {
  local watch=0 timeout_s=600
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) change_usage ;;
      --watch) watch=1; shift ;;
      --timeout) timeout_s=${2:-}; shift 2 || fail "missing_value_for_--timeout" ;;
      --timeout=*) timeout_s=${1#--timeout=}; shift ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  [[ $timeout_s =~ ^[0-9]+$ ]] || fail "VERIFICATION_TIMEOUT_NOT_A_NUMBER"
  # A zero or negative deadline would make --watch a no-op that reports `pending`,
  # which reads like "we looked and it was running" when in fact we never looked.
  ((timeout_s > 0)) || fail "VERIFICATION_TIMEOUT_NOT_POSITIVE"

  local mech=mechanism_verification_snapshot payload=''
  if ((watch)); then
    mech=mechanism_verification_wait
    # The deadline is owned by this verb so the mechanism only has to honour it:
    # two layers each with their own idea of the timeout is one too many.
    payload=$("$mech" "$timeout_s" 2>/dev/null) || true
  else
    payload=$("$mech" 2>/dev/null) || true
  fi

  # A mechanism that dies without saying why is the one failure this verb cannot
  # report honestly, so it is named rather than smoothed over.
  [[ -n $payload ]] || fail "VERIFICATION_UNREADABLE"

  # A refused wait arrives as an error object with the partial data attached. It
  # is reported as a failure WITH the verdict, never instead of it: a caller that
  # loses the state because the deadline passed has strictly less information than
  # one that got it, and this is exactly the case where it needs it most.
  local reason
  reason=$(printf '%s' "$payload" | jq -r '.error // empty' 2>/dev/null) || reason=''
  if [[ -n $reason ]]; then
    local extra
    extra=$(printf '%s' "$payload" \
      | jq -c --arg reason "$reason" 'del(.error) + {reason: $reason}' 2>/dev/null) || extra=''
    [[ -n $extra ]] || extra=$(jq -nc --arg reason "$reason" '{reason: $reason}')
    fail "$reason" "$extra"
  fi

  local out
  out=$(printf '%s' "$payload" | jq -c --argjson watched "$( ((watch)) && printf true || printf false )" '
    {
      ok: true,
      verification: {
        state: (.state // "unknown"),
        passing: (.passing // false),
        # Rebuilt field by field rather than passed through: the entries carry the
        # run identity the mechanism needs to block on a wait, and that identity is
        # not part of the domain answer.
        results: [(.results // [])[] | {name: .name, status: .status, conclusion: .conclusion}],
        suspicious: (.suspicious // []),
        detail: ""
      },
      total: (.total // 0),
      pending: (.pending // 0),
      watched: $watched,
      timed_out: (.timed_out // false),
      waited_seconds: (.waited_seconds // 0)
    }' 2>/dev/null) || out=''
  [[ -n $out ]] || fail "VERIFICATION_UNREADABLE"

  # A result that is neither success nor failure is surfaced, never swallowed.
  # The readiness gate does not act on it — changing what that gate accepts is a
  # separate decision — but an operator reading this output should not have to
  # open the forge to discover it.
  # `warn` is the ARRAY from core.sh, not a function: there is no `warn()` to
  # call, and calling one anyway kills the verb with "command not found" the
  # moment there is anything to report — which is exactly the moment the caller
  # needed an answer.
  local odd item
  odd=$(printf '%s' "$out" | jq -r '.verification.suspicious[]? | "\(.name)=\(.conclusion)"' 2>/dev/null) || odd=''
  while IFS= read -r item; do
    [[ -n $item ]] || continue
    warn+=("result $item is not a clean success; readiness counts it as not-failed")
  done <<<"$odd"

  printf '%s\n' "$out" | jq -c --argjson warnings "$(warnings_json)" '. + {warnings: $warnings}'
  exit 0
}