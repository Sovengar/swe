#!/usr/bin/env bash
# common.sh — shared helpers for the change/repository domain verbs. Everything
# here stays in the domain vocabulary: the modules name a destination, a change,
# readiness and a history shape, and reach the concrete mechanism only through
# the internal seam (mechanism.sh).

swe_source_once core.sh change/mechanism.sh change/usage.sh change/how-to-test.sh

# Runs one mechanism fact function, capturing its JSON and its status. The
# mechanism never prints anything else on stdout, so a bare command substitution
# is enough; stderr is progress chatter and is dropped.
mech_capture() {
  MECH_OUT=''
  MECH_RC=0
  MECH_OUT=$("$@" 2>/dev/null) || MECH_RC=$?
}

# Field of the last captured mechanism JSON.
mech_get() { printf '%s' "$MECH_OUT" | jq -r "$1"; }

# Error literal of the last captured mechanism failure.
mech_error() { printf '%s' "$MECH_OUT" | jq -r '.error // "unknown"'; }

# The line `open-issue` writes into the planning issue file. It is the run's
# durable link to the tracked item: whoever publishes the change reads it here
# instead of asking the tracker a second time, and it travels with the artifact
# so a resumed run still finds it.
issue_marker_line() { # <issue-file> → the marker line, or nothing
  local file=$1 marker=''
  [[ -f $file ]] || return 0
  marker=$(grep -m1 -E '^Forge-Issue:' "$file" 2>/dev/null) || marker=''
  [[ -n $marker ]] && printf '%s\n' "$marker"
  return 0
}

# The tracked item a change closes: an explicit number, or the marker the
# publishing verb wrote into the planning issue file. Shared by the verbs that
# publish and integrate, so the two can never disagree about where the number
# comes from, and so neither has to re-ask the tracker for a fact it already
# wrote down.
#
# Returns the number on stdout. Status: 0 found-or-absent, 2 the file cannot be
# read, 3 the number is malformed. It never fails the process: a caller that
# gets a non-zero status owns the refusal, because only it knows which reason
# literal belongs to its own surface.
change_issue_number() { # <issue-number> <issue-file> → number
  local issue=$1 issue_file=$2 marker=''
  if [[ -n $issue_file && ! -f $issue_file ]]; then return 2; fi
  if [[ -z $issue && -n $issue_file ]]; then
    marker=$(issue_marker_line "$issue_file")
    if [[ -n $marker ]]; then
      issue=$(printf '%s\n' "$marker" | awk '{print $2}')
      # A marker with the number missing is malformed, exactly like a number that
      # is not one: silently unlinking would hide a broken artifact.
      [[ -n $issue ]] || return 3
    fi
  fi
  if [[ -n $issue && ! $issue =~ ^[0-9]+$ ]]; then return 3; fi
  printf '%s\n' "$issue"
  return 0
}

# The repository's verification policy: what proves this change is safe to
# integrate when the hosted verification is ABSENT. Declared at the repository
# root in `.change-verification` (first non-empty, non-# line): `local` says the
# repository's own suite is the verification, so an absent hosted verdict does
# not block — it is measured, not waived (see change_verify_local). Anything
# else, including no file, keeps the fail-closed default: absent blocks.
change_verification_policy() { # → "local" | "strict"
  local root='' line=''
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=''
  if [[ -n $root && -f $root/.change-verification ]]; then
    line=$(grep -vE '^[[:space:]]*(#|$)' "$root/.change-verification" 2>/dev/null | head -n1) || line=''
    line=${line//[[:space:]]/}
  fi
  if [[ $line == local ]]; then printf 'local\n'; else printf 'strict\n'; fi
}

# Run the repository's own verification — the proof the `local` policy relies
# on. Three outcomes, NOT two: `pass` may release an integration, `fail` is a
# red suite, and `unknown` means the repository declares no way to test, which
# is fail-closed forever and never reads as a pass. The suite's output goes to
# stderr so the entrypoint's stdout stays one line of JSON.
change_verify_local() { # → "pass" | "fail" | "unknown"
  _htt_detect || { printf 'unknown\n'; return 0; }
  # shellcheck disable=SC2154  # _htt_command/_htt_from are set by _htt_detect
  if bash -c "$_htt_command" >&2; then printf 'pass\n'; else printf 'fail\n'; fi
}

# Resolve the destination and fail the calling verb when the mechanism cannot.
# On success sets DEST_REPOSITORY and DEST_BASE.
change_resolve_destination() {
  mech_capture mechanism_destination
  if [[ $MECH_RC -ne 0 ]]; then
    fail "$(mech_error)"
  fi
  DEST_REPOSITORY=$(mech_get '.repository')
  DEST_BASE=$(mech_get '.integration_base')
}
