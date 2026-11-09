#!/usr/bin/env bash
# publish-guards.sh — the two publication verbs, their shape refusals, and the
# axis split itself.
#
# Why this suite exists: there used to be ONE publication verb, offered in every
# isolation because a forge existed. In a shared run it then resolved the
# integration base to the branch it was already on and asked the forge to open
# `--base main --head main`. The forge refused, the domain could only report
# PUBLISH_FAILED, and an agent read that as transient.
#
# The verbs are now split by what publishing means:
#   publish-change  push        (shared: the branch IS the destination)
#   propose-change  pull request (worktree: the branch is proposed into a base)
#
# Every case here is offline. The push runs against a local bare repository.
#
# Run with: bash tests/publish-guards.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(dirname "$HERE")

resolve_entry() { # <name>
  local candidate="$ROOT/$1.sh"
  [[ -f $candidate ]] && printf '%s\n' "$candidate"
}

PIPELINE=$(resolve_entry swe-pipeline) || true
ISOLATION=$(resolve_entry isolation) || true
LEGACY=$(resolve_entry swe) || true

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP  publish-guards: requires git + jq"
  exit 0
fi
if [[ -z $PIPELINE || -z $ISOLATION ]]; then
  echo "FAIL  publish-guards: entrypoints missing (pipeline=[$PIPELINE] isolation=[$ISOLATION])"
  exit 1
fi

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1 CI=true
GITC=(-c user.email=swe@example.invalid -c user.name=swe-test)

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
check() { # check <label> <expected> <actual>
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A push must work with NO integration base configured: it targets the branch's
# own upstream. A propose-change needs the base, so it gets one explicitly.
run_push() { # run_push <dir> <args...>
  local dir=$1; shift
  ( cd "$dir" && bash "$PIPELINE" "$@" 2>/dev/null )
}
run_propose() { # run_propose <dir> <args...>
  local dir=$1; shift
  ( cd "$dir" && SWE_INTEGRATION_BASE=main bash "$PIPELINE" "$@" 2>/dev/null )
}

echo "=== A. shared: publish-change is a push ==="
git init -q --bare -b main "$WORK/origin.git"
git init -q -b main "$WORK/work"
git -C "$WORK/work" remote add origin "$WORK/origin.git"
git -C "$WORK/work" "${GITC[@]}" commit -q --allow-empty -m init

out=$(run_push "$WORK/work" publish-change)
check "first push ok"     true          "$(printf '%s' "$out" | jq -r '.ok')"
check "first push state"  "pushed"      "$(printf '%s' "$out" | jq -r '.state')"
check "first push no PR"  "null"        "$(printf '%s' "$out" | jq -r '.change')"
check "origin got the ref" "main" "$(git -C "$WORK/origin.git" rev-parse --abbrev-ref main)"

out=$(run_push "$WORK/work" publish-change)
check "up-to-date refuses" false "$(printf '%s' "$out" | jq -r '.ok')"
check "up-to-date reason" "NO_COMMITS_TO_PUBLISH" "$(printf '%s' "$out" | jq -r '.reason')"

git -C "$WORK/work" "${GITC[@]}" commit -q --allow-empty -m work
out=$(run_push "$WORK/work" publish-change)
check "second push ok" true "$(printf '%s' "$out" | jq -r '.ok')"
check "second push count" 1 "$(printf '%s' "$out" | jq -r '.commits_ahead')"

echo "=== B. a push cannot be a draft ==="
out=$(run_push "$WORK/work" publish-change --open)
check "--open rejected" false "$(printf '%s' "$out" | jq -r '.ok')"
check "--open reason" "open_not_supported_by_publish_change" "$(printf '%s' "$out" | jq -r '.reason')"

echo "=== C. propose-change refuses the base branch ==="
P="$WORK/propose-base"
git init -q -b main "$P"
git -C "$P" "${GITC[@]}" commit -q --allow-empty -m init
git -C "$P" remote add origin https://github.com/example/repo.git
out=$(run_propose "$P" propose-change)
check "branch==base reason" "CHANGE_BRANCH_IS_BASE" "$(printf '%s' "$out" | jq -r '.reason')"
check "names the branch" "main" "$(printf '%s' "$out" | jq -r '.branch')"
check "names the base"   "main" "$(printf '%s' "$out" | jq -r '.integration_base')"

echo "=== D. propose-change refuses an empty change branch ==="
git init -q -b feat/demo "$WORK/propose-empty"
git -C "$WORK/propose-empty" "${GITC[@]}" commit -q --allow-empty -m init
git -C "$WORK/propose-empty" branch main
git -C "$WORK/propose-empty" remote add origin https://github.com/example/repo.git
out=$(run_propose "$WORK/propose-empty" propose-change)
check "zero-ahead reason" "NO_COMMITS_TO_PUBLISH" "$(printf '%s' "$out" | jq -r '.reason')"

echo "=== E. each entrypoint rejects the other axis ==="
out=$( ( cd "$WORK/work" && bash "$ISOLATION" propose-change 2>/dev/null ) )
check "isolation rejects a pipeline verb" "unknown_subcommand_propose-change" "$(printf '%s' "$out" | jq -r '.reason')"
out=$( ( cd "$WORK/work" && bash "$PIPELINE" ensure --type feature --slug demo 2>/dev/null ) )
check "pipeline rejects an isolation verb" "unknown_subcommand_ensure" "$(printf '%s' "$out" | jq -r '.reason')"

echo "=== F. the deprecated dispatcher still routes both ways ==="
if [[ -n $LEGACY ]]; then
  out=$( ( cd "$WORK/work" && bash "$LEGACY" location 2>/dev/null ) )
  check "dispatcher routes location" true "$(printf '%s' "$out" | jq -r '.ok')"
  out=$( ( cd "$WORK/propose-base" && SWE_INTEGRATION_BASE=main bash "$LEGACY" propose-change 2>/dev/null ) )
  check "dispatcher routes propose-change" "CHANGE_BRANCH_IS_BASE" "$(printf '%s' "$out" | jq -r '.reason')"
else
  ok "dispatcher absent, nothing to route"
fi

echo "=== G. stdout purity ==="
out=$(run_push "$WORK/work" publish-change --open)
check "single json line" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check "has warnings"     true "$(printf '%s' "$out" | jq -r 'has("warnings")')"

echo "=== H. the tracked item reaches the published body ==="
# The link back to a tracked item lives in the published body, because that is
# the only place the tracker reads a closing reference. The stub records the argv
# it was given, so this asserts on what the mechanism actually asked for.
GH_LOG="$WORK/gh.log"
: > "$GH_LOG"
mk_gh_stub() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in
      *"--json number,state,isDraft,mergeable,reviewDecision,reviews,statusCheckRollup"*)
        printf '%s\n' '{"number":7,"state":"OPEN","isDraft":true,"mergeable":"MERGEABLE","reviewDecision":"","reviews":[],"statusCheckRollup":[]}'
        exit 0 ;;
      *)
        # An already-proposed change: the suite flips this file to exercise the
        # refresh path instead of the create path.
        [[ -n ${GH_EXISTS_MARK:-} && -f $GH_EXISTS_MARK ]] && exit 0
        exit 1 ;;
    esac ;;
  "pr create") printf '%s\n' 'https://github.com/example/repo/pull/7'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$WORK/bin/gh"
}
mk_gh_stub
export PATH="$WORK/bin:$PATH"
export GH_LOG
export GH_EXISTS_MARK="$WORK/pr-exists"

P2="$WORK/propose-issue"
git init -q -b main "$P2"
git -C "$P2" "${GITC[@]}" commit -q --allow-empty -m init
git -C "$P2" checkout -q -b feat/demo
git -C "$P2" "${GITC[@]}" commit -q --allow-empty -m work
git -C "$P2" remote add origin https://github.com/example/repo.git

: > "$GH_LOG"
out=$(run_propose "$P2" propose-change --issue 42)
check "issue link published"  true          "$(printf '%s' "$out" | jq -r '.ok')"
check "issue link change"     "7"           "$(printf '%s' "$out" | jq -r '.change')"
check "issue link in body"    1             "$(grep -c 'Closes #42' "$GH_LOG")"
check "issue link title is the branch" "feat/demo" \
  "$(grep 'pr create' "$GH_LOG" | sed -E 's/.*--title ([^ ]+).*/\1/')"

# Without an item the body stays empty: no dangling keyword, no invented link.
: > "$GH_LOG"
out=$(run_propose "$P2" propose-change)
check "no issue no link"     0             "$(grep -c 'Closes #' "$GH_LOG")"
check "no issue still ok"    true          "$(printf '%s' "$out" | jq -r '.ok')"

# The marker is the second source, so a resumed run never repeats the number.
MARK="$WORK/issue.md"
printf '# Something\n\nForge-Issue: 53 https://example.invalid/o/r/issues/53\n' > "$MARK"
: > "$GH_LOG"
out=$(run_propose "$P2" propose-change --issue-file "$MARK")
check "marker link published" 1            "$(grep -c 'Closes #53' "$GH_LOG")"
check "marker link ok"       true          "$(printf '%s' "$out" | jq -r '.ok')"

# Input the caller can still fix is refused before anything leaves the machine.
out=$(run_propose "$P2" propose-change --issue not-a-number)
check "bad issue reason"     "invalid_issue_number" "$(printf '%s' "$out" | jq -r '.reason')"
check "bad issue value echoed" "not-a-number" "$(printf '%s' "$out" | jq -r '.issue')"
out=$(run_propose "$P2" propose-change --issue-file "$WORK/absent.md")
check "absent issue file reason" "issue_file_unreadable" "$(printf '%s' "$out" | jq -r '.reason')"

# A marker whose number is missing is malformed, not an unlinked run: silently
# unlinking would hide a broken artifact.
BADMARK="$WORK/issue-bad.md"
printf '# Something\n\nForge-Issue:\n' > "$BADMARK"
out=$(run_propose "$P2" propose-change --issue-file "$BADMARK")
check "marker without number reason" "invalid_issue_number" "$(printf '%s' "$out" | jq -r '.reason')"

# An already-proposed change with no item to link must still succeed: the body
# refresh is skipped, not a failing statement that aborts the run.
touch "$GH_EXISTS_MARK"
: > "$GH_LOG"
out=$(run_propose "$P2" propose-change)
check "existing proposal no item ok" true "$(printf '%s' "$out" | jq -r '.ok')"
check "existing proposal no item no link" 0 "$(grep -c 'Closes #' "$GH_LOG")"

# ...and with an item, the refresh carries the link instead of opening a second
# proposal.
: > "$GH_LOG"
out=$(run_propose "$P2" propose-change --issue 42)
check "existing proposal links" 1 "$(grep -c 'Closes #42' "$GH_LOG")"
check "existing proposal no second create" 0 "$(grep -c 'pr create' "$GH_LOG")"
rm -f "$GH_EXISTS_MARK"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
