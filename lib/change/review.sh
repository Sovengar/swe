#!/usr/bin/env bash
# review.sh — the review loop's memory and its driver.
#
# Two facts live here, and both used to live in prompt prose:
#
#   1. WHERE the loop is. Every finished round is recorded (`record-review`) in
#      the change's own ledger, next to the run base the change verbs already
#      read. The next round therefore never depends on an agent remembering to
#      pass the reviewed tip, the round number or the streak in a message.
#   2. WHAT comes next. `review-round` answers with one packet: the range to
#      review, the lens set to run, and whether the loop continues or the change
#      opens with its surviving non-blocking findings deferred.
#
# The cap is by CLASS, never by count. A round whose findings are only MEDIUM or
# lower does not block on its own, and two such rounds in a row end the loop:
# real defects (CRITICAL, HIGH) loop at any round and reset the streak. The
# deferred findings travel back in the packet so the orchestrator can report
# them instead of leaving them silently unresolved.
#
# Nothing here names a tool: the loop position comes from the mechanism seam,
# like every other fact in the change layer.

swe_source_once core.sh change/common.sh

# The lens set of a first round. A lens is a review axis, not an agent: the
# reviewer runs its own prompt once per entry, so adding an axis is one edit
# here plus one prompt fragment. `behavior` is the contract gate and is always
# present, first.
readonly REVIEW_LENSES='behavior,code,security,performance,docs'

# --- pure helpers -----------------------------------------------------------

# The streak after a round: a medium-only round extends it, any CRITICAL or HIGH
# resets it, and a clean round resets it too because nothing is left to defer.
review_streak_next() { # <streak> <critical> <high> <medium> → n
  local streak=$1 critical=$2 high=$3 medium=$4
  if ((critical > 0 || high > 0)); then printf '0\n'; return 0; fi
  if ((medium > 0)); then printf '%d\n' "$((streak + 1))"; return 0; fi
  printf '0\n'
}

# Whether the loop continues or the change opens. `open` is the answer once the
# verdict passes, and once the medium-only cap fires; otherwise the findings go
# back to their author.
review_action() { # <verdict> <streak_after> → open|fix
  local verdict=$1 streak=$2
  if [[ $verdict == pass ]]; then printf 'open\n'; return 0; fi
  if ((streak >= 2)); then printf 'open\n'; return 0; fi
  printf 'fix\n'
}

# The axes a re-review must run: the contract gate, then only the axes that
# reported findings last round. A clean axis reviewed code nobody changed since,
# so re-running it is work whose answer is already known.
review_lenses_next() { # <csv of axes that had findings> → csv
  local reported=$1 lens out='behavior'
  local -a items=()
  IFS=',' read -r -a items <<<"$reported"
  for lens in "${items[@]}"; do
    [[ -n $lens ]] || continue
    [[ $lens == behavior ]] && continue
    case ",$out," in *",$lens,"*) continue ;; esac
    out="$out,$lens"
  done
  printf '%s\n' "$out"
}

_review_csv_to_json() { # <csv> → json array
  local csv=$1
  if [[ -z ${csv//,/} ]]; then printf '[]\n'; return 0; fi
  printf '%s\n' "$csv" | tr ',' '\n' | jq -R . | jq -sc .
}

# --- record-review ----------------------------------------------------------

cmd_record_review() {
  local tip='' verdict='' severity='{}' lenses='' verification=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --tip) tip=${2-}; shift 2 ;;
      --verdict) verdict=${2-}; shift 2 ;;
      --severity-json) severity=${2-}; shift 2 ;;
      --lenses-open) lenses=${2-}; shift 2 ;;
      --verification) verification=${2-}; shift 2 ;;
      -h | --help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  [[ -n $tip ]] || fail "REVIEW_TIP_REQUIRED"
  case $verdict in pass | fix) ;; *) fail "REVIEW_VERDICT_INVALID" ;; esac
  if ! printf '%s' "$severity" | jq -e 'type == "object"' >/dev/null 2>&1; then
    fail "REVIEW_SEVERITY_INVALID"
  fi

  mech_capture mechanism_review_state
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"

  local prev_streak=0 prev_round=0
  prev_streak=$(printf '%s' "$MECH_OUT" | jq -r '.ledger.medium_only_streak // 0')
  prev_round=$(printf '%s' "$MECH_OUT" | jq -r '.ledger.review_round // 0')

  local critical=0 high=0 medium=0 low=0
  critical=$(printf '%s' "$severity" | jq -r '.critical // 0')
  high=$(printf '%s' "$severity" | jq -r '.high // 0')
  medium=$(printf '%s' "$severity" | jq -r '.medium // 0')
  low=$(printf '%s' "$severity" | jq -r '.low // 0')

  local streak_after
  streak_after=$(review_streak_next "$prev_streak" "$critical" "$high" "$medium")

  # A passing verdict owes no further re-check; an unfinished one owes the gate
  # plus the axes that reported, so the next round is a delta over them.
  local open_lenses='[]'
  if [[ $verdict != pass ]]; then
    open_lenses=$(_review_csv_to_json "$(review_lenses_next "$lenses")")
  fi

  local ledger action
  ledger=$(jq -nc --arg tip "$tip" --arg verdict "$verdict" \
    --argjson round "$((prev_round + 1))" --argjson streak "$streak_after" \
    --argjson severity "$severity" --argjson lenses "$open_lenses" \
    --arg verification "$verification" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {review_base: $tip, review_round: $round, medium_only_streak: $streak,
     verdict: $verdict, severity: $severity, lenses_open: $lenses,
     verification: $verification, updated_at: $now}')

  local stored='' rc=0
  stored=$(printf '%s' "$ledger" | mechanism_review_ledger_write 2>/dev/null) || rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$(printf '%s' "$stored" | jq -r '.error // "REVIEW_LEDGER_WRITE_FAILED"')"
  fi

  action=$(review_action "$verdict" "$streak_after")

  jq -nc --argjson review "$ledger" --arg action "$action" \
    --argjson warnings "$(warnings_json)" \
    '{ok: true, review: $review, action: $action, warnings: $warnings}'
  exit 0
}

# --- review-round -----------------------------------------------------------

cmd_review_round() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  change_resolve_destination

  mech_capture mechanism_review_state
  [[ $MECH_RC -eq 0 ]] || fail "$(mech_error)"

  local head='' ledger='{}'
  head=$(printf '%s' "$MECH_OUT" | jq -r '.head // ""')
  ledger=$(printf '%s' "$MECH_OUT" | jq -c '.ledger // {}')
  [[ -n $head ]] || fail "REVIEW_HEAD_UNKNOWN"

  local base='' streak=0 round=0 verdict='' severity='{}' deferred_medium=0
  base=$(printf '%s' "$ledger" | jq -r '.review_base // ""')
  streak=$(printf '%s' "$ledger" | jq -r '.medium_only_streak // 0')
  round=$(printf '%s' "$ledger" | jq -r '.review_round // 0')
  verdict=$(printf '%s' "$ledger" | jq -r '.verdict // ""')
  severity=$(printf '%s' "$ledger" | jq -c '.severity // {}')

  local first range lenses nothing_new=false
  if [[ -z $base ]]; then
    # No ledger: the whole change is unreviewed, so this is the first round and
    # the range is the change itself.
    first=true
    range="$DEST_BASE...$head"
    lenses=$REVIEW_LENSES
    round=0
  else
    # A recorded round narrows everything to what moved since it.
    first=false
    range="$base..$head"
    lenses=$(printf '%s' "$ledger" | jq -r '
      ["behavior"] + ((.lenses_open // []) | map(select(. != "behavior")))
      | unique | join(",")')
    [[ -n $lenses ]] || lenses='behavior'
    [[ $base == "$head" ]] && nothing_new=true
  fi

  local action=review
  if [[ $verdict == pass ]] || ((streak >= 2)); then action=open; fi
  if [[ $action == open && $verdict != pass ]]; then
    deferred_medium=$(printf '%s' "$severity" | jq -r '.medium // 0')
  fi

  local lenses_json
  lenses_json=$(_review_csv_to_json "$lenses")

  jq -nc --argjson first "$first" --argjson round "$round" --arg range "$range" \
    --arg head "$head" --argjson lenses "$lenses_json" --argjson streak "$streak" \
    --arg action "$action" --argjson nothing_new "$nothing_new" \
    --argjson deferred "$deferred_medium" --argjson warnings "$(warnings_json)" '
    {ok: true, first: $first, round: $round, range: $range, head: $head,
     lenses: $lenses, medium_only_streak: $streak, action: $action,
     nothing_new: $nothing_new, deferred_medium: $deferred, warnings: $warnings}'
  exit 0
}
