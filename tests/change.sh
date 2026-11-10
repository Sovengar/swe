#!/usr/bin/env bash
# change.sh — the change/repository verb suite. No network anywhere: the pure
# verbs are exercised from fixture trees, the mechanism-facing verbs through a
# command-injection seam (an injected single implementation), and the history
# mutation additionally against a real local repository so the git-backed
# rewrite and its content invariant are covered with real infrastructure.
#
# Run with: bash tests/change.sh   (exits non-zero if any case fails)

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(dirname "$HERE")
ENTRY="$ROOT/swe.sh"
MANIFEST="$ROOT/lib/change.manifest"
LIFECYCLE_MANIFEST="$ROOT/lib/verbs.manifest"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat CI=true

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
check() { # check <label> <expected> <actual>
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/swe-change.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
WORK="$tmp/work"
mkdir -p "$WORK"
FAKE_DIR="$tmp/fake"
mkdir -p "$FAKE_DIR"
FAKE="$tmp/fake-mechanism.sh"

# A single injected implementation. It reports facts from files, exactly like
# the real implementation would, so the domain layer is exercised on its own.
cat > "$FAKE" <<'EOF'
_fake() { # <name>
  local n=$1
  if [[ -f "$FAKE_DIR/$n.ok" ]]; then cat "$FAKE_DIR/$n.ok"; return 0; fi
  if [[ -f "$FAKE_DIR/$n.err" ]]; then cat "$FAKE_DIR/$n.err"; return 1; fi
  printf '{"error":"unexpected_call_%s"}\n' "$n"; return 1
}
mechanism_destination()        { _fake destination; }
mechanism_repository()         { _fake repository; }
mechanism_publish()            { printf "%s" "${1:-}" > "$FAKE_DIR/publish.open"; printf "%s" "${2:-}" > "$FAKE_DIR/publish.issue"; _fake publish; }
mechanism_push()               { _fake push; }
mechanism_change_view()        { _fake view; }
mechanism_integration_mode()   { _fake mode; }
mechanism_integration_compatibility() { _fake compatibility; }
mechanism_history_collapses()  { _fake collapses; }
mechanism_history_state()      { _fake history; }
mechanism_history_steps()      { _fake steps; }
mechanism_history_rewrite()    { printf '%s' "${1:-}" > "$FAKE_DIR/rewrite.plan"; _fake rewrite; }
mechanism_content_tree()       { if [[ -f "$FAKE_DIR/tree.$1" ]]; then cat "$FAKE_DIR/tree.$1"; else printf '%s' "${FAKE_TREE:-aaaa}"; fi; }
mechanism_history_reset()      { printf '%s' "${1:-}" > "$FAKE_DIR/reset"; }
mechanism_republish()          { touch "$FAKE_DIR/republish.called"; _fake republish; }
mechanism_integrate()          { _fake integrate; }
mechanism_cleanup()            { printf '%s' "${1:-}" > "$FAKE_DIR/cleanup.branch"; _fake cleanup; }
mechanism_open_issue()       { printf '%s' "${1:-}" > "$FAKE_DIR/issue.title"; cp "${2:-}" "$FAKE_DIR/issue.body" 2>/dev/null || true; _fake issue; }
mechanism_close_issue()      { printf '%s' "${1:-}" > "$FAKE_DIR/closed.issue"; _fake close; }
mechanism_verification_snapshot() { _fake ci; }
mechanism_verification_wait()     { printf '%s' "${1:-}" > "$FAKE_DIR/ci.wait"; _fake ci; }
mechanism_review_state()          { _fake review_state; }
mechanism_review_ledger_write()   { cat > "$FAKE_DIR/ledger.json"; _fake ledger_write; }
EOF

fake_ok()  { rm -f "$FAKE_DIR/$1.err"; printf "%s" "$2" > "$FAKE_DIR/$1.ok"; }
fake_err() { rm -f "$FAKE_DIR/$1.ok"; printf "%s" "$2" > "$FAKE_DIR/$1.err"; }
fake_clear() { rm -f "$FAKE_DIR"/*; }

invoke_in() { # <dir> <out> <err> [args...]
  local dir=$1 out=$2 err=$3
  shift 3
  ( cd "$dir" && SWE_CHANGE_MECHANISM="$FAKE" FAKE_DIR="$FAKE_DIR" \
      bash "$ENTRY" "$@" ) >"$out" 2>"$err"
}

# Same, but against the real implementation (no injected seam), for the cases
# that need real infrastructure.
invoke_real() { # <dir> <out> <err> [args...]
  local dir=$1 out=$2 err=$3
  shift 3
  ( cd "$dir" && unset SWE_CHANGE_MECHANISM FAKE_DIR \
      && bash "$ENTRY" "$@" ) >"$out" 2>"$err"
}

RUN_OUT='' RUN_RC=0
run_fake() { # [args...] — runs in WORK with the injected implementation
  run_fake_in "$WORK" "$@"
}
run_fake_in() { # <dir> [args...]
  local dir=$1; shift
  RUN_RC=0
  invoke_in "$dir" "$tmp/out" "$tmp/err" "$@" || RUN_RC=$?
  RUN_OUT=$(cat "$tmp/out")
}
# Same, against the real mechanism with the stubbed forge binaries on PATH, so the
# verbs that talk to a forge are covered end to end through the entrypoint.
run_real_in() { # <dir> [args...]
  local dir=$1; shift
  RUN_RC=0
  ( cd "$dir" && unset SWE_CHANGE_MECHANISM FAKE_DIR \
      && PATH="$STUBBIN:$PATH" bash "$ENTRY" "$@" ) >"$tmp/out" 2>"$tmp/err" || RUN_RC=$?
  RUN_OUT=$(cat "$tmp/out")
}
jout() { printf '%s' "$RUN_OUT" | jq -r "$1"; }

# --- real-mechanism scaffolding ---------------------------------------------
# Exercises the concrete implementation itself (no injected stub) through the
# documented command-injection seam: fake forge binaries on PATH. This is what
# keeps a stubbed domain test from "revealing" behavior the real mechanism never
# has.
STUBBIN="$tmp/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# `-q <field>` has to actually extract. Without it a newly added query shape
# silently returns a whole JSON document where a scalar is expected, and the test
# that should cover it passes for the wrong reason.
field=''; want_q=0; args=()
for a in "$@"; do
  if [[ $want_q == 1 ]]; then field=$a; want_q=0; continue; fi
  if [[ $a == -q ]]; then want_q=1; continue; fi
  args+=("$a")
done
case " $* " in
  *" run list "*)
    # The await-ci read: runs of the current head, filtered by sha on the caller's
    # side. GH_RUNS_JSON is the payload as `gh run list --json` would print it.
    #
    # It is stateful on purpose. GH_RUNS_FINISH_AFTER_FIRST models the case that
    # actually happens when you wait: the first read sees a running check and the
    # second sees it finished. A stub that always answers the same thing can only
    # test the loop's exit, never the loop.
    state="$(dirname "${BASH_SOURCE[0]}")/.runs_calls"
    n=$(cat "$state" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" > "$state"
    if (( n > 1 )) && [[ ${GH_RUNS_FINISH_AFTER_FIRST:-0} == 1 ]]; then
      printf '%s' "${GH_RUNS_DONE_JSON:-[]}"
    else
      printf '%s' "${GH_RUNS_JSON:-[]}"
    fi
    # A matched case branch FALLS THROUGH to whatever follows the esac. These two
    # branches have to end in an explicit exit: without it the stub keeps going,
    # lands in the pr-view parsing below it, and answers the run-list request with
    # the merge-request payload (or exit 1). The failure looks like a broken
    # implementation, not a broken stub.
    exit 0
    ;;
  *" run watch "*)
    # Blocking. GH_WATCH_BLOCKS models a run that does not finish on its own, so
    # a test can prove the DEADLINE is what ends the wait.
    if [[ ${GH_WATCH_BLOCKS:-0} == 1 ]]; then
      touch "$(dirname "${BASH_SOURCE[0]}")/.watched"
      while :; do sleep 60; done
    fi
    touch "$(dirname "${BASH_SOURCE[0]}")/.watched"
    exit "${GH_WATCH_RC:-0}"
    ;;
  *" pr merge "*)
    # A merge can land on the server and still leave this process non-zero when
    # its LOCAL branch cleanup fails — which is what happens whenever the branch
    # is checked out in a worktree. GH_MERGE_LANDED models that: the PR really
    # is MERGED afterwards, and the exit code still says the command failed.
    [[ ${GH_MERGE_LANDED:-0} == 1 ]] && touch "$(dirname "${BASH_SOURCE[0]}")/.merged"
    exit "${GH_MERGE_RC:-0}"
    ;;
  *" issue create "*)
    # Recorded so a test can prove a resume never reaches the forge a second
    # time. ISSUE_OUTPUT models a forge that reports success WITHOUT a URL.
    printf '%s\n' "$*" >> "$(dirname "${BASH_SOURCE[0]}")/.gh_issue_calls"
    if [[ -n ${ISSUE_OUTPUT:-} ]]; then
      printf '%s\n' "$ISSUE_OUTPUT"
    else
      printf 'https://github.com/example/repo/issues/42\n'
    fi
    exit 0
    ;;
  *" issue close "*)
    printf '%s\n' "$*" >> "$(dirname "${BASH_SOURCE[0]}")/.gh_issue_closed"
    exit 0
    ;;
esac
view=${GH_VIEW_JSON:-}
if [[ ${GH_MERGE_LANDED:-0} == 1 && -f "$(dirname "${BASH_SOURCE[0]}")/.merged" ]]; then
  view=$(jq -c '.state="MERGED"' <<<"$view" 2>/dev/null) || view="$view"
fi
case " $* " in
  *" .mergeable "*) printf '%s' "${GH_MERGEABLE:-}"; [[ -n ${GH_MERGEABLE:-} ]] ;;
  *" pr view "*)
    [[ -n $field ]] && printf '%s' "$view" | jq -r "$field" || printf '%s' "$view"
    [[ -n $view ]]
    ;;
  *) exit 1 ;;
esac
EOF
cat > "$STUBBIN/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"issue create"*)
    # The argv is recorded verbatim: the test asserts the body travels as a
    # FILE and never as an argument.
    printf '%s\n' "$*" >> "${GLAB_ARGV_FILE:-$(dirname "${BASH_SOURCE[0]}")/.glab_issue_argv}"
    printf '%s\n' "${GLAB_ISSUE_URL:-https://gitlab.com/example/repo/-/issues/7}"
    exit 0
    ;;
  *"issue close"*)
    printf '%s\n' "$*" >> "${GLAB_CLOSE_FILE:-$(dirname "${BASH_SOURCE[0]}")/.glab_issue_closed}"
    exit 0
    ;;
  *"/approvals"*)
    if [[ ${GLAB_APPROVALS_RC:-0} != 0 ]]; then exit "${GLAB_APPROVALS_RC}"; fi
    printf '%s' "${GLAB_APPROVALS_JSON:-}" ;;
  *"merge_requests?source_branch"*) printf '%s' "${GLAB_MR_JSON:-}" ;;
  *" ci status "*)
    # The blocking path. GLAB_LIVE_BLOCKS models a pipeline that never ends, so
    # the test can prove the deadline is what stops the wait, not the pipeline.
    # Explicit exit for the same reason as the gh stub: a matched case branch
    # falls through to whatever follows the esac.
    if [[ ${GLAB_LIVE_BLOCKS:-0} == 1 ]]; then
      while :; do sleep 60; done
    fi
    printf 'ci status ok\n'
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUBBIN/gh" "$STUBBIN/glab"

mech_eval() { # mech_eval <repo> <fn> [args...] — real mechanism, stubbed forge
  local repo=$1; shift
  ( cd "$repo" && PATH="$STUBBIN:$PATH" SWE_LIB="$ROOT/lib" bash -c '
      set -euo pipefail
      . "$SWE_LIB/core.sh"; _SWE_SOURCED=(core.sh)
      . "$SWE_LIB/change/mechanism.sh"
      "$@"' bash "$@" )
}

mk_repo() { # mk_repo <dir> <remote>
  mkdir -p "$1"
  (
    cd "$1" || exit 1
    git init -q -b main .
    git config user.email swe@example.invalid
    git config user.name swe-test
    git commit -q --allow-empty -m 'chore: base'
    git checkout -q -b feat/demo
    git commit -q --allow-empty -m 'feat(model): work'
    git remote add origin "$2"
  )
}

json_lines() { printf '%s\n' "$RUN_OUT" | grep -c . || true; }

# Runs a pure domain function from a minimal source (core + the module), reading
# the sequence on stdin — the fixture-tree style for the branch-free logic.
pure() { # pure <function> [args...]
  (
    SWE_LIB="$ROOT/lib"
    # shellcheck source=/dev/null
    . "$SWE_LIB/core.sh"
    _SWE_SOURCED=(core.sh)
    # shellcheck source=/dev/null
    . "$SWE_LIB/change/history.sh"
    "$@"
  )
}

has_single_json_line() { # <label>
  check "$1 stdout-lines" "1" "$(json_lines)"
  if printf '%s' "$RUN_OUT" | jq -e . >/dev/null 2>&1; then ok "$1 jq"; else bad "$1 jq"; fi
  check "$1 has-ok" true "$(printf '%s' "$RUN_OUT" | jq -r 'has("ok")')"
}

# Vocabulary guard regexes (see the binding scope in context.md). The surface
# list is the full forbidden set; the prompt list bans the mechanism vocabulary
# actually extracted, while leaving operational git work (`git`, `branch`,
# `commit`, `push`) and the SWE workflow's own word "pipeline" alone.
SURFACE_FORBIDDEN='\bgh\b|\bglab\b|\bwt\b|\bgit\b|[Gg]it[Hh]ub|[Gg]it[Ll]ab|\bforge\b|\bPR\b|\bMR\b|[Pp]ull [Rr]equest|[Mm]erge [Rr]equest|\bdraft\b|\bCI\b|pipeline|\bchecks\b|branch protection|\bsquash\b|\brebase\b|\bbranch\b|\bcommit\b|\bworktree\b|\bmerge\b|\bremote\b|\borigin\b'
PROMPT_FORBIDDEN='\bgh\b|\bglab\b|\bwt\b|[Gg]it[Hh]ub|[Gg]it[Ll]ab|\bforge\b|\bPR\b|\bMR\b|[Pp]ull [Rr]equest|[Mm]erge [Rr]equest|\bdraft\b|\bCI\b|head_pipeline|\bchecks\b|branch protection|\bsquash\b|rebase[ -]merge|allow_rebase_merge|merge_method|delete_branch_on_merge|remove_source_branch'

echo "=== A. routing and manifest integrity ==="

# Every domain verb dispatches (never unknown) and rejects a bad argument the
# same way the lifecycle verbs do.
while IFS=$'\t' read -r verb module fn; do
  [[ -n $verb && $verb != \#* ]] || continue
  if [[ -f "$ROOT/lib/$module" ]]; then ok "manifest file: $verb -> $module"
  else bad "manifest file: $verb -> $module (missing)"; fi
  run_fake "$verb" --zz-unknown-flag
  check "dispatch:     $verb" "unknown_argument_--zz-unknown-flag" "$(jout '.reason // "-"')"
done <"$MANIFEST"

# Every row declares a function that exists after sourcing the module with only
# core.sh pre-sourced (the loader contract).
fn_exists() { # <module-file> <function>
  ( SWE_LIB="$ROOT/lib"
    . "$SWE_LIB/core.sh"
    _SWE_SOURCED=(core.sh)
    . "$SWE_LIB/$1"
    declare -F "$2" >/dev/null 2>&1 )
}
while IFS=$'\t' read -r verb module fn; do
  [[ -n $verb && $verb != \#* ]] || continue
  if fn_exists "$module" "$fn"; then ok "manifest fn:   $verb -> $fn"
  else bad "manifest fn:   $verb -> $fn (undefined after sourcing $module)"; fi
done <"$MANIFEST"

# Lifecycle wins on collision: the two manifests must not share a verb.
lverbs=$(awk -F'\t' 'NF && $1 !~ /^#/ {print $1}' "$LIFECYCLE_MANIFEST")
dverbs=$(awk -F'\t' 'NF && $1 !~ /^#/ {print $1}' "$MANIFEST")
overlap=$(comm -12 <(printf '%s\n' "$lverbs" | sort) <(printf '%s\n' "$dverbs" | sort) | grep -c . || true)
check "no lifecycle/domain overlap" 0 "$overlap"

# The change layer is not consulted for an unrelated failure.
run_fake definitely-not-a-verb
check "unknown verb" "unknown_subcommand_definitely-not-a-verb" "$(jout '.reason')"
check "unknown verb exit" 1 "$RUN_RC"

# Explicit help on a domain verb must print the domain usage, not the lifecycle
# one, and it must not leak a JSON line on stdout.
for v in how-to-test mutation-scope change-status open-issue publish-change propose-change record-review review-round ready-to-integrate \
         shape-change-history integrate-change clean-up-after-integration; do
  invoke_in "$WORK" "$tmp/out" "$tmp/err" "$v" -h; RUN_RC=$?
  check "usage $v exit" 2 "$RUN_RC"
  check "usage $v stdout" "" "$(cat "$tmp/out")"
  if grep -q "swe ensure" "$tmp/err"; then
    bad "usage $v is not lifecycle help"
  else
    ok "usage $v is not lifecycle help"
  fi
done
invoke_in "$WORK" "$tmp/out" "$tmp/err" shape-change-history plan -h; RUN_RC=$?
check "usage shape-change-history plan exit" 2 "$RUN_RC"
check "usage shape-change-history plan stdout" "" "$(cat "$tmp/out")"

echo "=== B. how-to-test (pure, fail-closed) ==="
htt="$tmp/htt"
mkdir -p "$htt/declared-target" "$htt/declared-script" "$htt/automation" "$htt/language" "$htt/empty"
printf 'test:\n\t@echo ok\n' > "$htt/declared-target/Makefile"
printf '{"scripts":{"test":"jest"}}\n' > "$htt/declared-script/package.json"
printf 'stages: [test]\ntest:\n  script:\n    - pytest\n' > "$htt/automation/.gitlab-ci.yml"
touch "$htt/language/test_widget.py"

invoke_in "$htt/declared-target" "$tmp/out" "$tmp/err" how-to-test; RUN_OUT=$(cat "$tmp/out"); RUN_RC=$?
check "htt declared command" "make test" "$(jout '.command')"
check "htt declared from" "declared_target" "$(jout '.detected_from')"
has_single_json_line "htt"

invoke_in "$htt/declared-script" "$tmp/out" "$tmp/err" how-to-test; RUN_OUT=$(cat "$tmp/out")
check "htt script command" "npm test" "$(jout '.command')"
check "htt script from" "declared_script" "$(jout '.detected_from')"

invoke_in "$htt/automation" "$tmp/out" "$tmp/err" how-to-test; RUN_OUT=$(cat "$tmp/out")
check "htt automation command" "pytest" "$(jout '.command')"
check "htt automation from" "automation_job" "$(jout '.detected_from')"

invoke_in "$htt/language" "$tmp/out" "$tmp/err" how-to-test; RUN_OUT=$(cat "$tmp/out")
check "htt language from" "language_suite" "$(jout '.detected_from')"

invoke_in "$htt/empty" "$tmp/out" "$tmp/err" how-to-test; RUN_RC=$?; RUN_OUT=$(cat "$tmp/out")
check "htt empty reason" "VERIFICATION_UNKNOWN" "$(jout '.reason')"
check "htt empty exit" 1 "$RUN_RC"
check "htt empty warnings" true "$(jout 'has("warnings")')"

echo "=== B3. integration base resolution (real git, repo-native) ==="

# A repository whose default branch is main declares it through origin/HEAD.
# The resolved base must be main, with the source reported, never the constant.
base_repo="$tmp/base-main"
mkdir -p "$base_repo"
(
  cd "$base_repo" || exit 1
  git init -q -b main .
  git config user.email swe@example.invalid
  git config user.name swe-test
  git commit -q --allow-empty -m 'chore: base one'
  git commit -q --allow-empty -m 'chore: base two'
  git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git checkout -q -b feat/demo
  git commit -q --allow-empty -m 'feat: work'
  git remote add origin "https://github.com/o/r.git"
)

RUN_RC=0; mech_eval "$base_repo" mechanism_destination > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "base resolved" "main" "$(jq -r '.integration_base' <"$tmp/out")"
check "base source" "origin_head" "$(jq -r '.base_source' <"$tmp/out")"
check "base exit" 0 "$RUN_RC"

# The explicit escape hatch still wins over everything.
RUN_RC=0; SWE_INTEGRATION_BASE=release mech_eval "$base_repo" mechanism_destination > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "base env override" "release" "$(jq -r '.integration_base' <"$tmp/out")"
check "base env source" "environment" "$(jq -r '.base_source' <"$tmp/out")"

# What costs nothing is tried before what can cost seconds: a tracking ref that
# names another branch resolves with no network at all, and a remote that does
# not exist cannot make the verb wait for it.
up_repo="$tmp/base-upstream"
mkdir -p "$up_repo"
(
  cd "$up_repo" || exit 1
  git init -q -b main .
  git config user.email swe@example.invalid
  git config user.name swe-test
  git commit -q --allow-empty -m 'chore: base one'
  git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  git remote add origin "$tmp/no-such-remote.git"
  git checkout -q -b feat/work
  git branch --set-upstream-to=origin/main feat/work >/dev/null 2>&1
  git commit -q --allow-empty -m 'feat: work'
)
RUN_RC=0; mech_eval "$up_repo" mechanism_destination > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "base upstream before network" "main" "$(jq -r '.integration_base' <"$tmp/out")"
check "base upstream source" "upstream" "$(jq -r '.base_source' <"$tmp/out")"

# The base declared for THIS run (swe-run-base, written by ensure) outranks the
# repository's own default: the change integrates into the checkout the run was
# invoked from, not into whatever the remote happens to call default. This is
# the whole point of the capture — before it, the PR went to `main` even when
# the work branched from `develop`.
run_repo="$tmp/base-run"
mkdir -p "$run_repo"
(
  cd "$run_repo" || exit 1
  git init -q -b main .
  git config user.email swe@example.invalid
  git config user.name swe-test
  git commit -q --allow-empty -m 'chore: base one'
  git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git branch release
  git checkout -q -b feat/demo
  git commit -q --allow-empty -m 'feat: work'
  git remote add origin "https://github.com/o/r.git"
)
run_gitdir=$(git -C "$run_repo" rev-parse --absolute-git-dir)
printf 'release\n' > "$run_gitdir/swe-run-base"
RUN_RC=0; mech_eval "$run_repo" mechanism_destination > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "run-base base" "release" "$(jq -r '.integration_base' <"$tmp/out")"
check "run-base source" "run_base" "$(jq -r '.base_source' <"$tmp/out")"

# The operator's explicit override still outranks the run's own declaration.
RUN_RC=0; SWE_INTEGRATION_BASE=hotfix mech_eval "$run_repo" mechanism_destination > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "run-base env wins" "hotfix" "$(jq -r '.integration_base' <"$tmp/out")"
check "run-base env wins source" "environment" "$(jq -r '.base_source' <"$tmp/out")"

# A stale declaration (a name this tree cannot resolve) is skipped, not obeyed:
# it is a leftover, not a base, and the repository's own default answers.
printf 'gone-branch\n' > "$run_gitdir/swe-run-base"
RUN_RC=0; mech_eval "$run_repo" mechanism_destination > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "run-base stale falls back" "main" "$(jq -r '.integration_base' <"$tmp/out")"
check "run-base stale source" "origin_head" "$(jq -r '.base_source' <"$tmp/out")"
rm -f "$run_gitdir/swe-run-base"

# The history base is the merge-base with the RESOLVED base, not the root
# commit. main advanced before the branch, so root != main tip: the two answers
# are distinguishable, which is exactly what the old fallback got wrong.
RUN_RC=0; mech_eval "$base_repo" mechanism_history_state > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "history base is merge-base" "$(git -C "$base_repo" rev-parse main)" "$(jq -r '.base' <"$tmp/out")"
if [[ "$(jq -r '.base' <"$tmp/out")" == "$(git -C "$base_repo" rev-list --max-parents=0 HEAD | head -n1)" ]]; then
  bad "history base is not the root commit"
else
  ok "history base is not the root commit"
fi

# A destination read through the domain verb reports the resolved value, not
# the constant. (change-status reads the real change view through the stub.)
GH_VIEW_JSON='{"number":1,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","reviews":[],"statusCheckRollup":[]}' \
  run_real_in "$base_repo" change-status
check "status resolved base" "main" "$(jout '.integration_base')"

# An unresolvable base is a named error, never a root-commit guess.
no_base="$tmp/base-none"
mkdir -p "$no_base"
(
  cd "$no_base" || exit 1
  git init -q -b main .
  git config user.email swe@example.invalid
  git config user.name swe-test
  git commit -q --allow-empty -m 'chore: base'
  git checkout -q -b feat/demo
  git commit -q --allow-empty -m 'feat: work'
)
RUN_RC=0; mech_eval "$no_base" mechanism_history_state > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "history unresolved reason" "INTEGRATION_BASE_UNKNOWN" "$(jq -r '.error' <"$tmp/out")"
check "history unresolved exit" 1 "$RUN_RC"
check "history unresolved no base" "null" "$(jq -r '.base' <"$tmp/out")"

RUN_RC=0; mech_eval "$no_base" mechanism_destination > "$tmp/out" 2>"$tmp/err" || RUN_RC=$?
check "destination unresolved reason" "INTEGRATION_BASE_UNKNOWN" "$(jq -r '.error' <"$tmp/out")"

echo "=== C. change-status (normalized view) ==="
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok view '{"change":"42","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":2,"verification":{"state":"none","detail":""}}'
fake_ok review_state '{"head":"aaaa","ledger":{}}'
run_fake change-status
has_single_json_line "status"
check "status repository" "deadbeef" "$(jout '.repository')"
check "status integration_base" "dev" "$(jout '.integration_base')"
check "status change" "42" "$(jout '.change')"
check "status state" "proposed" "$(jout '.state')"
check "status open" true "$(jout '.open_for_integration')"
check "status integratable" true "$(jout '.integratable')"
check "status requested" false "$(jout '.requested_changes')"
check "status endorsements" 2 "$(jout '.endorsements')"
check "status absent verification" "absent" "$(jout '.verification.state')"

# pending is not conflated with absent
fake_ok view '{"change":"42","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":0,"verification":{"state":"pending","detail":""}}'
fake_ok review_state '{"head":"aaaa","ledger":{}}'
run_fake change-status
check "status pending preserved" "pending" "$(jout '.verification.state')"

# no mechanism vocabulary in the emitted output
if printf '%s' "$RUN_OUT" | grep -Eq "$SURFACE_FORBIDDEN"; then bad "status output vocabulary"; else ok "status output vocabulary"; fi

fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_err view '{"error":"CHANGE_NOT_PUBLISHED"}'
run_fake change-status
check "status unpublished reason" "CHANGE_NOT_PUBLISHED" "$(jout '.reason')"

fake_clear
fake_err destination '{"error":"INTEGRATION_BASE_UNKNOWN"}'
run_fake change-status
check "status unknown base reason" "INTEGRATION_BASE_UNKNOWN" "$(jout '.reason')"

echo "=== D. publish-change ==="
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok publish '{"change":"7","state":"proposed","open_for_integration":false}'
run_fake propose-change
has_single_json_line "publish"
check "publish ok" true "$(jout '.ok')"
check "publish repository" "deadbeef" "$(jout '.repository')"
check "publish change" "7" "$(jout '.change')"
check "publish not open" false "$(jout '.open_for_integration')"
check "publish open flag sent" false "$(cat "$FAKE_DIR/publish.open")"

# idempotent: a second call succeeds with the same result
run_fake propose-change
check "publish idempotent ok" true "$(jout '.ok')"
check "publish idempotent change" "7" "$(jout '.change')"

# --open opens it for integration
fake_ok publish '{"change":"7","state":"proposed","open_for_integration":true}'
run_fake propose-change --open
check "publish --open flag sent" true "$(cat "$FAKE_DIR/publish.open")"
check "publish --open" true "$(jout '.open_for_integration')"

# half-finished publication reconciles: a published-but-not-open change can be
# re-entered and ends consistent with the requested state.
run_fake propose-change --open
check "publish reconcile ok" true "$(jout '.ok')"

fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_err publish '{"error":"PUBLISH_FAILED"}'
run_fake propose-change
check "publish failed reason" "PUBLISH_FAILED" "$(jout '.reason')"

# The tracked item the change closes reaches the mechanism, and an unlinked
# change sends nothing: the link is opt-in at publication, never invented.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok publish '{"change":"7","state":"proposed","open_for_integration":false}'
run_fake propose-change --issue 42
check "publish issue forwarded" "42" "$(cat "$FAKE_DIR/publish.issue")"
run_fake propose-change
check "publish unlinked sends nothing" "" "$(cat "$FAKE_DIR/publish.issue")"

# The marker the publishing verb wrote into the planning issue file is read
# here, so a run that already opened its item never has to repeat the number.
oi_pub="$tmp/oi-pub.md"
printf '# Something\n\nForge-Issue: 53 https://example.invalid/o/r/issues/53\n' > "$oi_pub"
run_fake propose-change --issue-file "$oi_pub"
check "publish issue from marker" "53" "$(cat "$FAKE_DIR/publish.issue")"

printf '# Something\n' > "$oi_pub"
run_fake propose-change --issue-file "$oi_pub"
check "publish markerless file sends nothing" "" "$(cat "$FAKE_DIR/publish.issue")"

run_fake propose-change --issue-file "$tmp/absent-issue.md"
check "publish issue file missing reason" "issue_file_unreadable" "$(jout '.reason')"

run_fake propose-change --issue 'not-a-number'
check "publish bad issue reason" "invalid_issue_number" "$(jout '.reason')"

# A change nothing will ever verify says so AT PUBLICATION — the moment acting
# on it is still cheap — and only when the repository declares no local policy:
# a warning that fires for every repo would be a warning nobody reads.
fake_ok publish '{"change":"7","state":"proposed","open_for_integration":false,"verification_state":"none"}'
run_fake propose-change
check "publish absent warns" "verification_absent" "$(jout '.warnings[0]')"
check "publish absent warns count" 1 "$(jout '.warnings|length')"

# Something reports for this change → no warning: there is a verdict coming.
fake_ok publish '{"change":"7","state":"proposed","open_for_integration":false,"verification_state":"passing"}'
run_fake propose-change
check "publish passing silent" 0 "$(jout '.warnings|length')"

# The repository's own `local` declaration silences it: it verifies its own
# way, and the gates honour that declaration (exercised in E2 / H below).
pol_pub="$tmp/pol-pub"
mk_repo "$pol_pub" "https://github.com/o/r.git"
printf 'local\n' > "$pol_pub/.change-verification"
echo "=== D2. review ledger (record-review / review-round) ==="

# A change nobody reviewed: no ledger, so the driver answers first round and the
# full range; the view reports review:null rather than an empty object.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"aaaa","ledger":{}}'
fake_ok view '{"change":"7","state":"proposed","open_for_integration":false,"integratable":false,"requested_changes":false,"endorsements":0,"verification":{"state":"none","detail":""}}'
run_fake review-round
has_single_json_line "review-round"
check "rr first" true "$(jout '.first')"
check "rr round" 0 "$(jout '.round')"
check "rr range" "dev...aaaa" "$(jout '.range')"
check "rr lenses" "behavior,code,security,performance,docs" "$(jout '.lenses | join(",")')"
check "rr action" review "$(jout '.action')"
check "rr nothing_new" false "$(jout '.nothing_new')"

run_fake change-status
check "status review null" null "$(jout '.review')"

# A recorded medium-only round: the streak starts and the next round is a delta
# over the gate plus the axis that reported.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"aaaa","ledger":{}}'
fake_ok ledger_write '{"stored":true}'
run_fake record-review --tip aaaa --verdict fix --severity-json '{"medium":2}' --lenses-open code
has_single_json_line "record-review"
check "record ok" true "$(jout '.ok')"
check "record streak" 1 "$(jout '.review.medium_only_streak')"
check "record round" 1 "$(jout '.review.review_round')"
check "record base" aaaa "$(jout '.review.review_base')"
check "record lenses" "behavior,code" "$(jout '.review.lenses_open | join(",")')"
check "record action" fix "$(jout '.action')"
check "record write" aaaa "$(jq -r '.review_base' "$FAKE_DIR/ledger.json")"

# A LOCAL-only round owes no re-check: a passing verdict opens.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"bbbb","ledger":{"review_base":"aaaa","review_round":1,"medium_only_streak":1,"verdict":"fix"}}'
fake_ok ledger_write '{"stored":true}'
run_fake record-review --tip bbbb --verdict pass --severity-json '{"low":3}'
check "record pass streak" 0 "$(jout '.review.medium_only_streak')"
check "record pass lenses" 0 "$(jout '.review.lenses_open | length')"
check "record pass action" open "$(jout '.action')"

# The second medium-only round in a row fires the cap by class: the change opens
# and the surviving findings travel back so they are not silently dropped.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"bbbb","ledger":{"review_base":"aaaa","review_round":1,"medium_only_streak":1,"verdict":"fix","severity":{"medium":2}}}'
fake_ok ledger_write '{"stored":true}'
run_fake record-review --tip bbbb --verdict fix --severity-json '{"medium":1}'
check "cap streak" 2 "$(jout '.review.medium_only_streak')"
check "cap action" open "$(jout '.action')"

# A real defect resets the streak: the cap never defers a CRITICAL or a HIGH.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"cccc","ledger":{"review_base":"bbbb","review_round":2,"medium_only_streak":2,"verdict":"fix"}}'
fake_ok ledger_write '{"stored":true}'
run_fake record-review --tip cccc --verdict fix --severity-json '{"critical":1,"medium":3}'
check "critical resets streak" 0 "$(jout '.review.medium_only_streak')"
check "critical action" fix "$(jout '.action')"

# A re-review packet: the range is the delta and the lens set is the gate plus
# only the axes that reported.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"dddd","ledger":{"review_base":"aaaa","review_round":1,"medium_only_streak":1,"verdict":"fix","lenses_open":["behavior","code"]}}'
run_fake review-round
check "delta first" false "$(jout '.first')"
check "delta range" "aaaa..dddd" "$(jout '.range')"
check "delta lenses" "behavior,code" "$(jout '.lenses | join(",")')"
check "delta action" review "$(jout '.action')"
check "delta nothing_new" false "$(jout '.nothing_new')"

# The cap already fired and nothing moved since: open, and say how many findings
# are being deferred.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"dddd","ledger":{"review_base":"dddd","review_round":2,"medium_only_streak":2,"verdict":"fix","severity":{"medium":1}}}'
run_fake review-round
check "capped action" open "$(jout '.action')"
check "capped nothing_new" true "$(jout '.nothing_new')"
check "capped deferred" 1 "$(jout '.deferred_medium')"

# The loop's position travels with the view: one call reports both.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"eeee","ledger":{"review_base":"dddd","review_round":2,"medium_only_streak":0,"verdict":"pass"}}'
fake_ok view '{"change":"7","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":0,"verification":{"state":"none","detail":""}}'
run_fake change-status
check "status review round" 2 "$(jout '.review.review_round')"
check "status review verdict" pass "$(jout '.review.verdict')"

# A refused record is refused the way every other verb refuses.
run_fake record-review --tip aaaa
check "tip without verdict" "REVIEW_VERDICT_INVALID" "$(jout '.reason')"
run_fake record-review --verdict pass
check "verdict without tip" "REVIEW_TIP_REQUIRED" "$(jout '.reason')"

# No mechanism vocabulary on the new surface either.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok review_state '{"head":"eeee","ledger":{"review_base":"dddd","review_round":2,"medium_only_streak":2,"verdict":"fix","severity":{"medium":1},"lenses_open":["behavior","code"]}}'
run_fake review-round
if printf '%s' "$RUN_OUT" | grep -Eq "$SURFACE_FORBIDDEN"; then bad "review-round output vocabulary"; else ok "review-round output vocabulary"; fi

# An unreachable ledger is a warning on the view, never a refusal: the change
# view itself is still a valid answer.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok view '{"change":"7","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":0,"verification":{"state":"none","detail":""}}'
fake_err review_state '{"error":"REPOSITORY_UNKNOWN"}'
run_fake change-status
check "status survives ledger failure" true "$(jout '.ok')"
check "status ledger warning" "review_state_unavailable" "$(jout '.warnings[0]')"

fake_clear
fake_ok publish '{"change":"7","state":"proposed","open_for_integration":false,"verification_state":"none"}'
run_fake_in "$pol_pub" publish-change
check "publish absent local silent" 0 "$(jout '.warnings|length')"

echo "=== D2. publish-change (shared: push) ==="
fake_clear
fake_ok repository '{"repository":"deadbeef"}'
fake_ok push '{"change":null,"state":"pushed","branch":"main","commits_ahead":1}'
run_fake publish-change
has_single_json_line "push"
check "push ok" true "$(jout '.ok')"
check "push repository" "deadbeef" "$(jout '.repository')"
check "push state" "pushed" "$(jout '.state')"
check "push no PR" null "$(jout '.change')"
check "push ignores base" "" "$(jout '.integration_base')"

# A push needs no integration base. If the destination resolver were consulted,
# this case would fail with INTEGRATION_BASE_UNKNOWN — the bug a fresh remote
# with no origin/HEAD produced.
fake_clear
fake_err destination '{"error":"INTEGRATION_BASE_UNKNOWN"}'
fake_ok repository '{"repository":"deadbeef"}'
fake_ok push '{"change":null,"state":"pushed"}'
run_fake publish-change
check "push without a base ok" true "$(jout '.ok')"

fake_clear
fake_ok repository '{"repository":"deadbeef"}'
fake_err push '{"error":"NO_COMMITS_TO_PUBLISH"}'
run_fake publish-change
check "push refusal reason" "NO_COMMITS_TO_PUBLISH" "$(jout '.reason')"

echo "=== E. ready-to-integrate ==="
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok mode '{"mode":"linear"}'
fake_ok view '{"change":"42","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":1,"verification":{"state":"passing","detail":""}}'
run_fake ready-to-integrate
has_single_json_line "ready"
check "ready true" true "$(jout '.ready')"
check "ready change not null" "42" "$(jout '.change')"

# pending verification is NOT ready: fail-closed like absent.
fake_ok view '{"change":"42","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":0,"verification":{"state":"pending","detail":""}}'
run_fake ready-to-integrate
check "ready pending reason" "NOT_READY_TO_INTEGRATE" "$(jout '.reason')"
check "ready pending blocker" "verification_pending" "$(jout '.blockers[0]')"

# absent verification fails closed
fake_ok view '{"change":"42","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":0,"verification":{"state":"none","detail":""}}'
run_fake ready-to-integrate
check "ready absent reason" "NOT_READY_TO_INTEGRATE" "$(jout '.reason')"
check "ready absent blocker" "verification_absent" "$(jout '.blockers[0]')"

# every blocker, in a fixed order
fake_ok mode '{"mode":"merge"}'
fake_ok view '{"change":"42","state":"proposed","open_for_integration":false,"integratable":false,"requested_changes":true,"endorsements":0,"verification":{"state":"failing","detail":""}}'
run_fake ready-to-integrate
check "ready all blockers" "not_open_for_integration requested_changes verification_failing integration_mode_not_linear" \
  "$(jout '.blockers | join(" ")')"

# unpublished
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok mode '{"mode":"linear"}'
fake_err view '{"error":"CHANGE_NOT_PUBLISHED"}'
run_fake ready-to-integrate
check "ready unpublished reason" "CHANGE_NOT_PUBLISHED" "$(jout '.reason')"

echo "=== E2. verification policy (.change-verification: local) ==="
# The policy decides what an ABSENT hosted verdict means, and `local` is a
# proof rather than a waiver: the repository's own suite is measured right
# here. A green suite releases; a red one blocks exactly like a red hosted
# verdict; and a repository that declares `local` but has no way to run tests
# stays fail-closed — "I could not find the tests" is never "the tests pass".
pol_pass="$tmp/pol-pass"
mk_repo "$pol_pass" "https://github.com/o/r.git"
printf 'local\n' > "$pol_pass/.change-verification"
printf 'test:\n\t@true\n' > "$pol_pass/Makefile"

fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"main"}'
fake_ok mode '{"mode":"linear"}'
fake_ok view '{"change":"42","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":1,"verification":{"state":"none","detail":""}}'
run_fake_in "$pol_pass" ready-to-integrate
check "local policy green ready" true "$(jout '.ok')"
check "local policy green ready flag" true "$(jout '.ready')"

printf 'test:\n\t@false\n' > "$pol_pass/Makefile"
run_fake_in "$pol_pass" ready-to-integrate
check "local policy red reason" "NOT_READY_TO_INTEGRATE" "$(jout '.reason')"
check "local policy red blocker" "verification_failing" "$(jout '.blockers[0]')"

# `local` declared, tests undeclared → the policy cannot be measured, so the
# blocker is the same fail-closed one as without any policy.
pol_unknown="$tmp/pol-unknown"
mk_repo "$pol_unknown" "https://github.com/o/r.git"
printf 'local\n' > "$pol_unknown/.change-verification"
run_fake_in "$pol_unknown" ready-to-integrate
check "local undetectable blocker" "verification_absent" "$(jout '.blockers[0]')"

# No local declaration (comment-only file) → the old strict behaviour: absent
# blocks. The policy is opt-in, never inferred.
printf '# nothing declared here\n' > "$pol_unknown/.change-verification"
run_fake_in "$pol_unknown" ready-to-integrate
check "strict absent blocker" "verification_absent" "$(jout '.blockers[0]')"
# (the file is restored to `local` where the later integrate tests need it)

echo "=== F. shape-change-history plan (pure, by concern + policy) ==="

# The pure grouping primitive: grouping is by concern, not contiguity. Every
# step of a concern belongs to one unit no matter where it sits; units follow
# each concern's first appearance. The canonical 12-step example has three
# concerns (model, readme, make) -> one unit each.
canon='feat	model
feat	model
feat	model
test	model
feat	model
docs	readme
docs	readme
docs	readme
chore	make
chore	make
feat	model
feat	model
'
units=$(printf '%s' "$canon" | pure history_units one-per-concern)
check "canon units" 3 "$(printf '%s\n' "$units" | grep -c .)"
check "canon unit order" "model readme make" "$(printf '%s\n' "$units" | cut -f3 | paste -sd' ' -)"
check "canon unit sizes" "7 3 2" "$(printf '%s\n' "$units" | cut -f1 | awk '{print NF}' | paste -sd' ' -)"

single=$(printf '%s' "$canon" | pure history_units single-unit)
check "single-unit units" 1 "$(printf '%s\n' "$single" | grep -c .)"
check "single-unit members" 12 "$(printf '%s\n' "$single" | cut -f1 | wc -w | tr -d ' ')"
check "single-unit concerns" "model readme make" "$(printf '%s\n' "$single" | cut -f4)"

maxd=$(printf '%s' "$canon" | pure history_units max 2)
check "max2 units" 2 "$(printf '%s\n' "$maxd" | grep -c .)"
check "max2 folded unit concerns" "readme make" "$(printf '%s\n' "$maxd" | sed -n '2p' | cut -f4)"
check "max2 no concern dropped" "make model readme" \
  "$(printf '%s\n' "$maxd" | cut -f4 | tr ' ' '\n' | sort -u | paste -sd' ' -)"

# Same concern grouped even when not adjacent; ordered by first appearance.
inter=$(printf 'feat\ta\ndocs\tb\nfeat\ta\ndocs\tb\n' | pure history_units one-per-concern)
check "interleaved units" 2 "$(printf '%s\n' "$inter" | grep -c .)"
check "interleaved unit a members" "0 2" "$(printf '%s\n' "$inter" | sed -n '1p' | cut -f1)"
check "interleaved unit b members" "1 3" "$(printf '%s\n' "$inter" | sed -n '2p' | cut -f1)"

# The set of units does not depend on the order concerns appear in; the order of
# the units does, and it is the first appearance, never the alphabet.
order=$(printf 'docs\ta\nfeat\tz\ndocs\ta\nfeat\tz\n' | pure history_units one-per-concern)
check "order by first appearance" "a z" "$(printf '%s\n' "$order" | cut -f3 | paste -sd' ' -)"

# A single-concern change yields exactly one unit (correct, not a collapse).
one=$(printf 'docs\ta\ndocs\ta\nchore\ta\n' | pure history_units one-per-concern)
check "single concern one unit" 1 "$(printf '%s\n' "$one" | grep -c .)"

# Plan through the domain module with injected facts: default policy.
fake_clear
rm -f "$WORK/.change-shape"
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[{"type":"feat","scope":"a","subject":"feat(a): one"},{"type":"docs","scope":"b","subject":"docs(b): two"},{"type":"feat","scope":"a","subject":"feat(a): three"}]}'
run_fake shape-change-history plan
has_single_json_line "plan"
check "plan ok" true "$(jout '.ok')"
check "plan units" 2 "$(jout '.units | length')"
check "plan concerns" "a b" "$(jout '.concerns | join(" ")')"
check "plan default policy" "one-per-concern" "$(jout '.evidence.policy.name')"
check "plan policy from default" true "$(jout '.evidence.policy.from_default')"
check "plan reason default" "one unit per concern (default policy)" "$(jout '.evidence.reason')"
check "plan not collapsed" false "$(jout '.evidence.collapsed')"
check "plan message contract" true "$(jout '.message_contract.one_message_per_group')"
plan1="$RUN_OUT"
run_fake shape-change-history plan
check "plan deterministic" "$plan1" "$RUN_OUT"

# A repository may declare the whole change as a single unit.
printf 'single-unit\n' > "$WORK/.change-shape"
run_fake shape-change-history plan
check "plan single-unit units" 1 "$(jout '.units | length')"
check "plan single-unit policy" "single-unit" "$(jout '.evidence.policy.name')"
check "plan single-unit collapsed" true "$(jout '.evidence.collapsed')"

# A repository may declare a cap; overflow folds, never dropping a concern.
printf 'max:2\n' > "$WORK/.change-shape"
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[{"type":"feat","scope":"a","subject":"feat(a): one"},{"type":"docs","scope":"b","subject":"docs(b): two"},{"type":"chore","scope":"c","subject":"chore(c): three"}]}'
run_fake shape-change-history plan
check "plan max units" 2 "$(jout '.units | length')"
check "plan max folded reported" 1 "$(jout '.evidence.folded | length')"
check "plan max folded concerns" "c" "$(jout '.evidence.folded[0].folded_concerns | join(" ")')"
check "plan max concerns kept" 3 "$(jout '[.units[].concerns[]] | unique | length')"

# The fold is idempotent at the shape level: re-planning the shape it produced
# yields the same number and scopes of units, and needs no further fold. The
# folded concerns' identity is evidence of the plan that produced the shape, not
# something the emitted commits can carry.
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[{"type":"feat","scope":"a","subject":"feat(a): one"},{"type":"docs","scope":"b","subject":"docs(b): two"}]}'
run_fake shape-change-history plan
check "max2 replan units" 2 "$(jout '.units | length')"
check "max2 replan scopes" "a b" "$(jout '.units | map(.scope) | join(" ")')"
check "max2 replan no further fold" 0 "$(jout '.evidence.folded | length')"
check "max2 replan already shaped" true "$(jout '.already_shaped')"

# The declaration is resolved against the repository, not the caller's cwd: a
# verb run from a subdirectory must not silently ignore it.
mkdir -p "$WORK/sub/deep"
printf 'single-unit\n' > "$WORK/.change-shape"
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[{"type":"feat","scope":"a","subject":"feat(a): one"},{"type":"docs","scope":"b","subject":"docs(b): two"}]}'
run_fake_in "$WORK/sub/deep" shape-change-history plan
check "policy from subdir" "single-unit" "$(jout '.evidence.policy.name')"
check "policy subdir units" 1 "$(jout '.units | length')"
rm -rf "$WORK/sub"
rm -f "$WORK/.change-shape"

# A single-concern change: one unit, reported as expected, not a collapse.
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[{"type":"docs","scope":"a","subject":"docs(a): one"},{"type":"chore","scope":"a","subject":"chore(a): two"}]}'
run_fake shape-change-history plan
check "plan single-concern units" 1 "$(jout '.units | length')"
check "plan single-concern not collapsed" false "$(jout '.evidence.collapsed')"
check "plan single-concern reason" "one unit per concern (default policy)" "$(jout '.evidence.reason')"

# Idempotency by construction: an already-shaped history plans to itself.
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[{"type":"feat","scope":"a","subject":"feat(a): one"},{"type":"docs","scope":"b","subject":"docs(b): two"}]}'
run_fake shape-change-history plan
check "plan shaped units scopes" "a b" "$(jout '.units | map(.scope) | join(" ")')"
check "plan shaped already" true "$(jout '.already_shaped')"

# The obsolete non-convergence reason is gone from code and prompts.
if grep -Rq "HISTORY_NOT_CONVERGED" "$ROOT/lib/change" "$ROOT/../../../dot_config/opencode/agents" 2>/dev/null; then
  bad "HISTORY_NOT_CONVERGED removed"
else
  ok "HISTORY_NOT_CONVERGED removed"
fi

fake_ok history '{"head":"H","base":"B","unsaved":true,"protected":false,"steps":[]}'
run_fake shape-change-history plan
check "plan unsaved reason" "UNSAVED_CHANGES" "$(jout '.reason')"
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":true,"steps":[]}'
run_fake shape-change-history plan
check "plan protected reason" "INTEGRATION_BASE_PROTECTED" "$(jout '.reason')"

echo "=== G. shape-change-history apply ==="

# Injected content mismatch: rolled back with HISTORY_REWRITE_CHANGED_CONTENT.
fake_clear
fake_ok history '{"head":"H0","base":"B","unsaved":false,"protected":false,"steps":[{"type":"feat","scope":"a","subject":"feat(a): one"},{"type":"feat","scope":"a","subject":"feat(a): two"}]}'
fake_ok rewrite '{"head":"H1"}'
printf 'aaaa' > "$FAKE_DIR/tree.H0"
printf 'bbbb' > "$FAKE_DIR/tree.H1"
printf 'feat(a): consolidated\n' > "$tmp/messages.txt"
run_fake shape-change-history apply --messages "$tmp/messages.txt"
check "apply content mismatch reason" "HISTORY_REWRITE_CHANGED_CONTENT" "$(jout '.reason')"
check "apply content mismatch rolled back" "H0" "$(cat "$FAKE_DIR/reset" 2>/dev/null)"

# Injected rewrite failure: rolled back explicitly, reason propagated.
fake_clear
fake_ok history '{"head":"H0","base":"B","unsaved":false,"protected":false,"steps":[{"type":"feat","scope":"a","subject":"feat(a): one"},{"type":"feat","scope":"a","subject":"feat(a): two"}]}'
fake_err rewrite '{"error":"HISTORY_REWRITE_FAILED"}'
run_fake shape-change-history apply --messages "$tmp/messages.txt"
check "apply rewrite failure reason" "HISTORY_REWRITE_FAILED" "$(jout '.reason')"
check "apply rewrite failure rolled back" "H0" "$(cat "$FAKE_DIR/reset" 2>/dev/null)"

# Missing messages is a usage failure.
run_fake shape-change-history apply
check "apply missing messages" "missing_--messages" "$(jout '.reason')"

# Apply refuses unsaved work and a protected base, like the plan does.
fake_clear
fake_ok history '{"head":"H","base":"B","unsaved":true,"protected":false,"steps":[]}'
run_fake shape-change-history apply --messages "$tmp/messages.txt"
check "apply unsaved reason" "UNSAVED_CHANGES" "$(jout '.reason')"
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":true,"steps":[]}'
run_fake shape-change-history apply --messages "$tmp/messages.txt"
check "apply protected reason" "INTEGRATION_BASE_PROTECTED" "$(jout '.reason')"

# Real repository: the rewrite preserves content, collapses, and a second pass
# is a true no-op.
repo="$tmp/histrepo"
mkdir -p "$repo"
(
  cd "$repo" || exit 1
  git init -q -b main .
  git config user.email swe@example.invalid
  git config user.name swe-test
  printf 'base\n' > f.txt
  git add f.txt
  git commit -qm 'chore: base'
  # The repository's own declaration of its default branch: the base resolver
  # reads it, and there is no root-commit fallback to lean on any more.
  git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git checkout -q -b feat/demo
  printf '1\n' >> f.txt; git commit -qam 'feat(model): one'
  printf '2\n' >> f.txt; git commit -qam 'feat(model): two'
  printf '3\n' >> f.txt; git commit -qam 'test(model): t'
  printf '4\n' >> f.txt; git commit -qam 'docs(readme): r'
  printf '5\n' >> f.txt; git commit -qam 'feat(model): three'
)
tree_before=$(git -C "$repo" rev-parse 'HEAD^{tree}')
root=$(git -C "$repo" rev-list --max-parents=0 HEAD | head -n1)
printf 'feat(model): consolidated work\ndocs(readme): refresh docs\n' > "$tmp/real-messages.txt"
invoke_real "$repo" "$tmp/out" "$tmp/err" shape-change-history apply --messages "$tmp/real-messages.txt"; RUN_RC=$?; RUN_OUT=$(cat "$tmp/out")
check "apply real ok" true "$(jout '.ok')"
check "apply real exit" 0 "$RUN_RC"
tree_after=$(git -C "$repo" rev-parse 'HEAD^{tree}')
check "apply real content invariant" "$tree_before" "$tree_after"
check "apply real units" 2 "$(git -C "$repo" rev-list --count "$root..HEAD")"

invoke_real "$repo" "$tmp/out" "$tmp/err" shape-change-history apply --messages "$tmp/real-messages.txt"; RUN_OUT=$(cat "$tmp/out")
check "apply real second pass no-op" "HISTORY_ALREADY_SHAPED" "$(jout '.reason')"
check "apply real no-op content" "$tree_before" "$(git -C "$repo" rev-parse 'HEAD^{tree}')"

echo "=== H. integrate-change ==="
integrate_view_ok='{"change":"9","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":1,"verification":{"state":"passing","detail":""}}'

# The full happy-path mechanism set, so the close tests below express only what
# they are about: which item is closed, and whether closing changes the result.
integrate_stack_ok() {
  fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
  fake_ok mode '{"mode":"linear"}'
  fake_ok collapses '{"collapses":false}'
  fake_ok compatibility '{"compatibility":"ready"}'
  fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[]}'
  fake_ok republish '{"change":"9","state":"proposed","open_for_integration":true}'
  fake_ok view "$integrate_view_ok"
  fake_ok integrate '{"state":"integrated","noop":false}'
}

fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok mode '{"mode":"merge"}'
run_fake integrate-change
check "integrate non-linear reason" "INTEGRATION_MODE_UNSUPPORTED" "$(jout '.reason')"
check "integrate non-linear state" "merge" "$(jout '.mode')"

fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok mode '{"mode":"linear"}'
fake_ok collapses '{"collapses":true}'
run_fake integrate-change
check "integrate collapse reason" "HISTORY_WOULD_BE_COLLAPSED" "$(jout '.reason')"

fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok mode '{"mode":"linear"}'
fake_ok collapses '{"collapses":false}'
fake_ok compatibility '{"compatibility":"ready"}'
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[]}'
fake_err republish '{"error":"PUBLISH_FAILED"}'
run_fake integrate-change
check "integrate republish reason" "PUBLISH_FAILED" "$(jout '.reason')"

# A computed conflict aborts BEFORE re-publishing: nothing touches the remote.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok mode '{"mode":"linear"}'
fake_ok collapses '{"collapses":false}'
fake_ok compatibility '{"compatibility":"conflict"}'
run_fake integrate-change
check "integrate pre conflict reason" "INTEGRATION_CONFLICT" "$(jout '.reason')"
check "integrate pre conflict blocker" "conflict" "$(jout '.integration_blocker')"
check "integrate pre conflict not retryable" false "$(jout '.recovery.retryable')"
check "integrate pre conflict requires human" true "$(jout '.recovery.requires_human')"
check "integrate pre conflict not republished" false "$(jout '.recovery.change_republished')"
check "integrate pre conflict no republish" "" "$(cat "$FAKE_DIR/republish.called" 2>/dev/null)"

# A not-yet-computed compatibility is transient, never a human call, and never
# touches the remote.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok mode '{"mode":"linear"}'
fake_ok collapses '{"collapses":false}'
fake_ok compatibility '{"compatibility":"pending"}'
run_fake integrate-change
check "integrate pre pending reason" "INTEGRATION_FAILED" "$(jout '.reason')"
check "integrate pre pending blocker" "pending" "$(jout '.integration_blocker')"
check "integrate pre pending retryable" true "$(jout '.recovery.retryable')"
check "integrate pre pending not human" false "$(jout '.recovery.requires_human // false')"
check "integrate pre pending not republished" false "$(jout '.recovery.change_republished')"
check "integrate pre pending no republish" "" "$(cat "$FAKE_DIR/republish.called" 2>/dev/null)"

# After republishing, endorsements withdrawn and failing verification abort.
fake_clear
fake_ok destination '{"repository":"deadbeef","integration_base":"dev"}'
fake_ok mode '{"mode":"linear"}'
fake_ok collapses '{"collapses":false}'
fake_ok compatibility '{"compatibility":"ready"}'
fake_ok history '{"head":"H","base":"B","unsaved":false,"protected":false,"steps":[]}'
fake_ok republish '{"change":"9"}'
fake_ok view '{"change":"9","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":true,"endorsements":0,"verification":{"state":"passing","detail":""}}'
run_fake integrate-change
check "integrate endorsements reason" "ENDORSEMENTS_WITHDRAWN" "$(jout '.reason')"

fake_ok view '{"change":"9","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":1,"verification":{"state":"failing","detail":""}}'
run_fake integrate-change
check "integrate verification reason" "VERIFICATION_FAILED" "$(jout '.reason')"

# Already integrated is a clean no-op success.
fake_ok view '{"change":"9","state":"integrated","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":1,"verification":{"state":"passing","detail":""}}'
run_fake integrate-change
check "integrate already ok" true "$(jout '.ok')"
check "integrate already noop" true "$(jout '.noop')"
check "integrate already change" "9" "$(jout '.change')"

# Post-republish race: a conflict computed after publishing is still a human call.
fake_ok view "$integrate_view_ok"
fake_err integrate '{"error":"conflict"}'
run_fake integrate-change
check "integrate conflict reason" "INTEGRATION_CONFLICT" "$(jout '.reason')"
check "integrate conflict change" "9" "$(jout '.change')"
check "integrate conflict blocker" "conflict" "$(jout '.integration_blocker')"
check "integrate conflict not retryable" false "$(jout '.recovery.retryable')"
check "integrate conflict requires human" true "$(jout '.recovery.requires_human')"
check "integrate conflict republished" true "$(jout '.recovery.change_republished')"

# Post-republish pending is transient, not a conflict.
fake_err integrate '{"error":"pending"}'
run_fake integrate-change
check "integrate post pending reason" "INTEGRATION_FAILED" "$(jout '.reason')"
check "integrate post pending blocker" "pending" "$(jout '.integration_blocker')"
check "integrate post pending retryable" true "$(jout '.recovery.retryable')"
check "integrate post pending not human" false "$(jout '.recovery.requires_human // false')"

# Non-atomic failure reports an explicit recovery object.
fake_err integrate '{"error":"INTEGRATION_FAILED","partial":true}'
run_fake integrate-change
check "integrate failed reason" "INTEGRATION_FAILED" "$(jout '.reason')"
check "integrate failed change" "9" "$(jout '.change')"
check "integrate recovery republished" true "$(jout '.recovery.change_republished')"
check "integrate recovery not integrated" false "$(jout '.recovery.integrated')"
check "integrate recovery retryable" true "$(jout '.recovery.retryable')"

# Success.
fake_ok integrate '{"state":"integrated","noop":false}'
run_fake integrate-change
has_single_json_line "integrate"
check "integrate ok" true "$(jout '.ok')"
check "integrate integrated" true "$(jout '.integrated')"
check "integrate change not null" "9" "$(jout '.change')"

# The tracked item is closed AFTER a real integration, read from the marker the
# opening verb wrote: the run never has to repeat the number.
ci_pub="$tmp/close-issue.md"
printf '# Something\n\nForge-Issue: 77 https://example.invalid/o/r/issues/77\n' > "$ci_pub"
fake_clear
integrate_stack_ok
fake_ok close '{"ok":true,"forge":"github","number":77}'
run_fake integrate-change --issue-file "$ci_pub"
check "integrate closes tracked item" "77" "$(cat "$FAKE_DIR/closed.issue")"
check "integrate close ok" true "$(jout '.ok')"
check "integrate close silent" 0 "$(jout '.warnings|length')"

# Re-entry after a completed integration still closes: a run that integrated and
# then died before closing must end consistent, and closing twice is a no-op.
fake_ok view '{"change":"9","state":"integrated","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":1,"verification":{"state":"passing","detail":""}}'
rm -f "$FAKE_DIR/closed.issue"
run_fake integrate-change --issue 77
check "integrate reentry closes item" "77" "$(cat "$FAKE_DIR/closed.issue")"
check "integrate reentry noop" true "$(jout '.noop')"

# A tracker that refuses is a warning, never a failed integration: the change is
# integrated either way, and retrying the integrate would change nothing.
fake_clear
integrate_stack_ok
fake_err close '{"error":"ISSUE_CLOSE_FAILED"}'
run_fake integrate-change --issue 77
check "integrate close failure still ok" true "$(jout '.ok')"
check "integrate close failure integrated" true "$(jout '.integrated')"
check "integrate close failure warning" "issue_not_closed" "$(jout '.warnings[0]')"

# A run that never opened an item closes nothing: there is no marker and no
# number, and that is not a gap.
fake_clear
integrate_stack_ok
run_fake integrate-change
check "integrate unlinked closes nothing" "absent" \
  "$([[ -e $FAKE_DIR/closed.issue ]] && printf 'called' || printf 'absent')"


# The `local` policy at the integrate gate: the suite runs HERE, against the
# tree about to be integrated — a proof, not a waiver — and every non-green
# outcome keeps its own honest name.
printf 'test:\n\t@true\n' > "$pol_pass/Makefile"
fake_ok view '{"change":"9","state":"proposed","open_for_integration":true,"integratable":true,"requested_changes":false,"endorsements":1,"verification":{"state":"none","detail":""}}'
run_fake_in "$pol_pass" integrate-change
check "integrate local green ok" true "$(jout '.ok')"
check "integrate local green integrated" true "$(jout '.integrated')"

printf 'test:\n\t@false\n' > "$pol_pass/Makefile"
run_fake_in "$pol_pass" integrate-change
check "integrate local red reason" "VERIFICATION_FAILED" "$(jout '.reason')"
check "integrate local red state" "failing" "$(jout '.verification.state')"

printf 'local\n' > "$pol_unknown/.change-verification"
run_fake_in "$pol_unknown" integrate-change
check "integrate local unknown reason" "VERIFICATION_UNKNOWN" "$(jout '.reason')"
check "integrate local unknown state" "absent" "$(jout '.verification.state')"

# No local declaration → absent still fails closed, exactly as before: the
# policy added a path, it did not weaken the default.
printf '# nothing declared here\n' > "$pol_unknown/.change-verification"
run_fake_in "$pol_unknown" integrate-change
check "integrate absent strict reason" "VERIFICATION_FAILED" "$(jout '.reason')"
check "integrate absent strict state" "absent" "$(jout '.verification.state')"

echo "=== H2. real mechanism (stubbed forge binaries on PATH) ==="

ghrepo="$tmp/ghrepo"
mk_repo "$ghrepo" "https://github.com/o/r.git"

# The real view carries the handle and reports integratability/verification.
GH_VIEW_JSON='{"number":9,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}' \
  mech_eval "$ghrepo" mechanism_change_view > "$tmp/out" 2>"$tmp/err"; RUN_RC=$?
RUN_OUT=$(cat "$tmp/out")
check "real view exit" 0 "$RUN_RC"
check "real view change" "9" "$(jout '.change')"
check "real view integratable" true "$(jout '.integratable')"
check "real view passing" "passing" "$(jout '.verification.state')"

# A real conflict: not mergeable against its base -> the mechanism itself emits
# `conflict`, distinct from a transient integration failure.
GH_VIEW_JSON='{"number":9,"state":"OPEN","isDraft":false,"mergeable":"CONFLICTING","reviewDecision":"","reviews":[],"statusCheckRollup":[]}' GH_MERGEABLE=CONFLICTING \
  mech_eval "$ghrepo" mechanism_integrate HEAD > "$tmp/out" 2>"$tmp/err"; RUN_RC=$?
check "real integrate conflict exit" 1 "$RUN_RC"
check "real integrate conflict error" "conflict" "$(jq -r '.error' <"$tmp/out")"

# Tri-state compatibility from the real mechanism: a not-yet-computed state is
# pending, never a conflict.
GH_MERGEABLE=UNKNOWN mech_eval "$ghrepo" mechanism_integration_compatibility > "$tmp/out" 2>"$tmp/err"
check "real compat unknown" "pending" "$(jq -r '.compatibility' <"$tmp/out")"
GH_MERGEABLE=CONFLICTING mech_eval "$ghrepo" mechanism_integration_compatibility > "$tmp/out" 2>"$tmp/err"
check "real compat conflicting" "conflict" "$(jq -r '.compatibility' <"$tmp/out")"
GH_MERGEABLE=MERGEABLE mech_eval "$ghrepo" mechanism_integration_compatibility > "$tmp/out" 2>"$tmp/err"
check "real compat mergeable" "ready" "$(jq -r '.compatibility' <"$tmp/out")"

# Real integrate on a not-yet-computed change is a transient pending, not a
# conflict.
GH_VIEW_JSON='{"number":9,"state":"OPEN","isDraft":false,"mergeable":"UNKNOWN","reviewDecision":"","reviews":[],"statusCheckRollup":[]}' GH_MERGEABLE=UNKNOWN \
  mech_eval "$ghrepo" mechanism_integrate HEAD > "$tmp/out" 2>"$tmp/err"; RUN_RC=$?
check "real integrate unknown exit" 1 "$RUN_RC"
check "real integrate unknown error" "pending" "$(jq -r '.error' <"$tmp/out")"

# A merge that genuinely did not happen: mergeable, the command fails, and the
# PR is still open afterwards. This must stay a failure — it is the case that
# stops the fix below from degenerating into "a non-zero exit is always fine".
rm -f "$STUBBIN/.merged"
GH_VIEW_JSON='{"number":9,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","reviews":[],"statusCheckRollup":[]}' GH_MERGEABLE=MERGEABLE GH_MERGE_RC=1 \
  mech_eval "$ghrepo" mechanism_integrate HEAD > "$tmp/out" 2>"$tmp/err"; RUN_RC=$?
check "real integrate genuine-failure exit" 1 "$RUN_RC"
check "real integrate genuine-failure error" "INTEGRATION_FAILED" "$(jq -r '.error' <"$tmp/out")"

# The bug this harness actually shipped: `gh pr merge --delete-branch` MERGES,
# then fails deleting the local branch because it is checked out in a worktree —
# which in this pipeline is always. The command exits non-zero and the merge has
# already happened. Reporting INTEGRATION_FAILED here sent the caller hunting for
# a merge that existed, on a branch whose PR no longer resolved by name.
#
# Verified in production: a merge landed as 6e99edb while integrate-change
# returned INTEGRATION_FAILED with `partial: true` on two separate calls.
rm -f "$STUBBIN/.merged"
GH_VIEW_JSON='{"number":9,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","reviews":[],"statusCheckRollup":[]}' \
GH_MERGEABLE=MERGEABLE GH_MERGE_RC=1 GH_MERGE_LANDED=1 \
  mech_eval "$ghrepo" mechanism_integrate HEAD > "$tmp/out" 2>"$tmp/err"; RUN_RC=$?
check "real integrate landed-despite-exit exit" 0 "$RUN_RC"
check "real integrate landed-despite-exit state" "integrated" "$(jq -r '.state' <"$tmp/out")"
check "real integrate landed-despite-exit noop" "false" "$(jq -r '.noop' <"$tmp/out")"
check "real integrate landed-despite-exit no error" "" "$(jq -r '.error // ""' <"$tmp/out")"

# A real success.
GH_VIEW_JSON='{"number":9,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","reviews":[],"statusCheckRollup":[]}' GH_MERGEABLE=MERGEABLE GH_MERGE_RC=0 \
  mech_eval "$ghrepo" mechanism_integrate HEAD > "$tmp/out" 2>"$tmp/err"; RUN_RC=$?
check "real integrate success exit" 0 "$RUN_RC"
check "real integrate success state" "integrated" "$(jq -r '.state' <"$tmp/out")"

# Real GitLab endorsements come from the approvals endpoint, never a silent 0.
glrepo="$tmp/glrepo"
mk_repo "$glrepo" "https://gitlab.com/g/s/r.git"
GLAB_MR_JSON='[{"iid":5,"state":"opened","draft":false,"merge_status":"can_be_merged","blocking_discussions_resolved":true,"head_pipeline":{"status":"success"}}]' \
GLAB_APPROVALS_JSON='{"approved_by":[{"user":1},{"user":2}]}' \
  mech_eval "$glrepo" mechanism_change_view > "$tmp/out" 2>"$tmp/err"; RUN_RC=$?
check "real gitlab view exit" 0 "$RUN_RC"
check "real gitlab change" "5" "$(jq -r '.change' <"$tmp/out")"
check "real gitlab endorsements" 2 "$(jq -r '.endorsements' <"$tmp/out")"

# When the approvals endpoint cannot be read, endorsements is explicitly null.
GLAB_MR_JSON='[{"iid":5,"state":"opened","draft":false,"merge_status":"can_be_merged","blocking_discussions_resolved":true,"head_pipeline":{"status":"success"}}]' \
GLAB_APPROVALS_RC=1 \
  mech_eval "$glrepo" mechanism_change_view > "$tmp/out" 2>"$tmp/err"; RUN_RC=$?
check "real gitlab unreadable exit" 0 "$RUN_RC"
check "real gitlab unreadable null" "null" "$(jq -r '.endorsements' <"$tmp/out")"

# Real GitLab compatibility is tri-state too: only an explicit
# `cannot_be_merged` is a conflict; a not-yet-computed state is pending.
GLAB_MR_JSON='[{"iid":5,"state":"opened","draft":false,"merge_status":"can_be_merged"}]' \
  mech_eval "$glrepo" mechanism_integration_compatibility > "$tmp/out" 2>"$tmp/err"
check "real gitlab compat ready" "ready" "$(jq -r '.compatibility' <"$tmp/out")"
GLAB_MR_JSON='[{"iid":5,"state":"opened","draft":false,"merge_status":"cannot_be_merged"}]' \
  mech_eval "$glrepo" mechanism_integration_compatibility > "$tmp/out" 2>"$tmp/err"
check "real gitlab compat conflict" "conflict" "$(jq -r '.compatibility' <"$tmp/out")"
GLAB_MR_JSON='[{"iid":5,"state":"opened","draft":false,"merge_status":"checking"}]' \
  mech_eval "$glrepo" mechanism_integration_compatibility > "$tmp/out" 2>"$tmp/err"
check "real gitlab compat pending" "pending" "$(jq -r '.compatibility' <"$tmp/out")"

echo "=== I. await-verification ==="

# --- the domain verb, through the injected mechanism -------------------------
# What the verb adds on top of the mechanism is the shape and the rule that `ok`
# is never a verdict. Those are properties of the contract, so they are checked
# where the contract is written.

fake_clear
fake_ok ci '{"state":"passing","passing":true,"failing":false,"total":2,"pending":0,"results":[{"name":"a","status":"completed","conclusion":"success"},{"name":"b","status":"completed","conclusion":"success"}],"suspicious":[]}'
run_fake await-verification
has_single_json_line "await-verification snapshot"
check "ok" true "$(jout '.ok')"
check "state" "passing" "$(jout '.verification.state')"
check "passing" true "$(jout '.verification.passing')"
check "total" 2 "$(jout '.total')"
check "pending" 0 "$(jout '.pending')"
check "not watched" false "$(jout '.watched')"
check "results count" 2 "$(jout '.verification.results | length')"

# `ok` is true for a failing verification too. That is not an oversight: `ok` says
# the question was answered. The test below pins it, because the tempting "fix"
# is to make ok=false on failure, which would make `ok` a second verdict to keep
# in sync with the first.
fake_ok ci '{"state":"failing","passing":false,"failing":true,"total":1,"pending":0,"results":[{"name":"b","status":"completed","conclusion":"failure"}],"suspicious":[]}'
run_fake await-verification
check "failing ok is still true" true "$(jout '.ok')"
check "failing state" "failing" "$(jout '.verification.state')"
check "failing passing flag" false "$(jout '.verification.passing')"

# `none` must never be readable as green. A change whose verification was never
# configured, or whose results are not visible, has no verdict — and the
# difference between "nothing ran" and "green" is the difference between a gate
# that means something and one that approves everything.
fake_ok ci '{"state":"none","passing":false,"failing":false,"total":0,"pending":0,"results":[],"suspicious":[]}'
run_fake await-verification
check "none state" "none" "$(jout '.verification.state')"
check "none passing" false "$(jout '.verification.passing')"

# A deadline that is not a number, or is zero, is refused. Zero would otherwise
# make --watch a no-op that reports `pending` without ever having looked.
run_fake await-verification --watch --timeout abc
check "timeout not a number" "VERIFICATION_TIMEOUT_NOT_A_NUMBER" "$(jout '.reason')"
run_fake await-verification --watch --timeout 0
check "timeout not positive" "VERIFICATION_TIMEOUT_NOT_POSITIVE" "$(jout '.reason')"

# --watch hands the deadline to the mechanism and says so.
fake_ok ci '{"state":"passing","passing":true,"total":1,"pending":0,"results":[],"suspicious":[]}'
run_fake await-verification --watch --timeout 42
check "watch passes the deadline" "42" "$(cat "$FAKE_DIR/ci.wait")"
check "watch flag" true "$(jout '.watched')"

# A deadline that expires is a failure WITH the verdict attached, not a failure
# that replaces it. The caller has strictly less information if the state is
# dropped, and this is exactly the case where it is needed.
fake_err ci '{"error":"VERIFICATION_WAIT_TIMEOUT","state":"pending","passing":false,"total":1,"pending":1,"timed_out":true,"waited_seconds":42,"results":[{"name":"b","status":"in_progress","conclusion":null}]}'
run_fake await-verification --watch --timeout 42
check "timeout reason" "VERIFICATION_WAIT_TIMEOUT" "$(jout '.reason')"
check "timeout keeps state" "pending" "$(jout '.state')"
check "timeout keeps results" 1 "$(jout '.results | length')"
check "timeout keeps waited" 42 "$(jout '.waited_seconds')"

# A mechanism that dies without an error object cannot be reported honestly.
fake_err ci ''
run_fake await-verification
check "unreadable" "VERIFICATION_UNREADABLE" "$(jout '.reason')"

# A conclusion that is neither success nor failure is surfaced, not swallowed.
fake_ok ci '{"state":"passing","passing":true,"total":1,"pending":0,"results":[{"name":"m","status":"completed","conclusion":"timed_out"}],"suspicious":[{"name":"m","conclusion":"timed_out"}]}'
run_fake await-verification
check "suspicious kept" "m=timed_out" "$(jout '.verification.suspicious[0].name + "=" + .verification.suspicious[0].conclusion')"
check "suspicious warned" 1 "$(jout '.warnings | length')"

# --- the real mechanism ------------------------------------------------------

GHSHA=$(git -C "$ghrepo" rev-parse HEAD)
gl_reset_fakes() { rm -f "$STUBBIN/.runs_calls" "$STUBBIN/.watched"; }
runs() { # runs <name> <conclusion> [status]
  jq -nc --arg sha "$GHSHA" --arg n "$1" --arg c "$2" --arg s "${3:-completed}" \
    '[{databaseId:1,workflowName:$n,status:$s,conclusion:$c,headSha:$sha}]'
}

# The default read must NOT block. This is the assertion that keeps the verb
# honest: an instant read that started waiting would hang every caller that
# forgot the flag, and there is no timeout on the snapshot path to save it.
gl_reset_fakes
GH_RUNS_JSON=$(runs Build success) run_real_in "$ghrepo" await-verification
check "github passing state" "passing" "$(jout '.verification.state')"
check "github passing watched" false "$(jout '.watched')"
if [[ -f $STUBBIN/.watched ]]; then bad "snapshot blocked"; else ok "snapshot never blocks"; fi

gl_reset_fakes
GH_RUNS_JSON=$(runs Test "" in_progress) run_real_in "$ghrepo" await-verification
check "github pending state" "pending" "$(jout '.verification.state')"
check "github pending count" 1 "$(jout '.pending')"

gl_reset_fakes
GH_RUNS_JSON=$(runs Test failure) run_real_in "$ghrepo" await-verification
check "github failing state" "failing" "$(jout '.verification.state')"
check "github failing passing" false "$(jout '.verification.passing')"

# The sha filter, not the name. A name outlives the push it was created from, so
# a result from an older commit must not be able to answer for the head — that is
# how a red run gets read as green after a force-push.
#
# The stale sha must be UNCONDITIONALLY different. Deriving it as "0" + head[1:]
# looks safe and is not: a sha that already starts with "0" makes it identical to
# the head, and the filter then correctly keeps the run — so the test failed on
# roughly one run in sixteen, on a sha nobody chose. Forty zeros cannot collide
# with a commit id.
gl_reset_fakes
STALE_SHA=$(printf '0%.0s' {1..40})
if [[ $STALE_SHA == "$GHSHA" ]]; then bad "test fixture: stale sha equals head"; fi
GH_RUNS_JSON=$(jq -nc --arg sha "$STALE_SHA" '[{databaseId:1,workflowName:"Old",status:"completed",conclusion:"failure",headSha:$sha}]') \
  run_real_in "$ghrepo" await-verification
check "stale sha ignored" "none" "$(jout '.verification.state')"
check "stale sha total" 0 "$(jout '.total')"

# A result list that cannot be read is its own error. Reporting it as `none`
# would turn a credentials problem into an approvable change.
gl_reset_fakes
cp "$STUBBIN/gh" "$tmp/gh.keep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/gh"; chmod +x "$STUBBIN/gh"
run_real_in "$ghrepo" await-verification
check "unreadable is not none" "VERIFICATION_MECHANISM_UNREADABLE" "$(jout '.reason')"
cp "$tmp/gh.keep" "$STUBBIN/gh"

# --- the wait ----------------------------------------------------------------

# A wait that resolves: the first read sees it running, the wait blocks, the
# second read sees it finished. This is the only case that exercises the loop.
gl_reset_fakes
GH_RUNS_JSON=$(runs Test "" in_progress) GH_RUNS_DONE_JSON=$(runs Test success) GH_RUNS_FINISH_AFTER_FIRST=1 \
  run_real_in "$ghrepo" await-verification --watch --timeout 30
check "wait resolves state" "passing" "$(jout '.verification.state')"
check "wait resolves watched" true "$(jout '.watched')"
check "wait resolves not timed out" false "$(jout '.timed_out')"
if [[ -f $STUBBIN/.watched ]]; then ok "wait actually blocked"; else bad "wait never blocked"; fi

# The deadline is the safety property. Without it the wait is an open-ended hold
# in an agent that cannot ask anyone, so the timeout has to actually stop it and
# the state has to survive the stop.
gl_reset_fakes
started=$SECONDS
GH_RUNS_JSON=$(runs Test "" in_progress) GH_WATCH_BLOCKS=1 \
  run_real_in "$ghrepo" await-verification --watch --timeout 3
elapsed=$((SECONDS - started))
check "deadline reason" "VERIFICATION_WAIT_TIMEOUT" "$(jout '.reason')"
check "deadline keeps pending" "pending" "$(jout '.state')"
check "deadline keeps timed_out" true "$(jout '.timed_out')"
check "deadline keeps waited" 3 "$(jout '.waited_seconds')"
if (( elapsed < 25 )); then ok "deadline stopped the wait (${elapsed}s)"; else bad "wait overran the deadline (${elapsed}s)"; fi

# GitLab reads the verdict from the merge request's own pipeline — the same source
# the change view uses — and blocks with the one command that resolves it itself.
gl_reset_fakes
GLAB_MR_JSON='[{"iid":5,"source_branch":"feat/demo","head_pipeline":{"ref":"main","status":"running"}}]' \
  run_real_in "$glrepo" await-verification
check "gitlab pending state" "pending" "$(jout '.verification.state')"
GLAB_MR_JSON='[{"iid":5,"source_branch":"feat/demo","head_pipeline":{"ref":"main","status":"success"}}]' \
  run_real_in "$glrepo" await-verification
check "gitlab passing state" "passing" "$(jout '.verification.state')"
GLAB_MR_JSON='[{"iid":5,"source_branch":"feat/demo","head_pipeline":{"ref":"main","status":"failed"}}]' \
  run_real_in "$glrepo" await-verification
check "gitlab failing state" "failing" "$(jout '.verification.state')"
GLAB_MR_JSON='[{"iid":5,"source_branch":"feat/demo","head_pipeline":null}]' \
  run_real_in "$glrepo" await-verification
check "gitlab no pipeline is none" "none" "$(jout '.verification.state')"
GLAB_MR_JSON='[{"iid":5,"source_branch":"other","head_pipeline":{"ref":"main","status":"failed"}}]' \
  run_real_in "$glrepo" await-verification
check "gitlab other branch ignored" "none" "$(jout '.verification.state')"

# The whole point of routing both readers through one classifier: the verb and
# the readiness gate must not be able to disagree about the same result set. If
# this ever fails, someone has re-inlined the rule.
GV=$(GH_VIEW_JSON='{"number":9,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","reviews":[],"statusCheckRollup":[{"name":"t","status":"COMPLETED","conclusion":"TIMED_OUT"}]}' \
     mech_eval "$ghrepo" mechanism_change_view)
GH_RUNS_JSON=$(runs Test timed_out) run_real_in "$ghrepo" await-verification
AC=$RUN_OUT
check "vocabulary agrees on a soft failure" \
  "$(printf '%s' "$GV" | jq -r '.verification.state')" \
  "$(printf '%s' "$AC" | jq -r '.verification.state')"

echo "=== I2. clean-up-after-integration ==="
# The change is the run's IDENTITY and the caller states it. It used to be read
# from the caller's cwd, which for the closer is something else entirely: the
# suite below asserted the JSON shape and never the argument, so nothing could
# tell the two apart. These cases assert what the mechanism was ASKED to remove.
fake_clear
fake_ok cleanup '{"cleaned":["workspace_released","local_change_removed"],"risks":[]}'
run_fake clean-up-after-integration --change fix/honest-mutation-gate
has_single_json_line "cleanup"
check "cleanup ok" true "$(jout '.ok')"
check "cleanup cleaned count" 2 "$(jout '.cleaned | length')"
check "cleanup no risks" 0 "$(jout '.risks | length')"
check "cleanup warnings present" true "$(jout 'has("warnings")')"
check "cleanup forwards the named change" "fix/honest-mutation-gate" "$(cat "$FAKE_DIR/cleanup.branch")"

# No change named is a refusal, not a guess: the one caller allowed outside the
# workspace has no identity of its own to fall back on.
fake_clear
fake_ok cleanup '{"cleaned":[],"risks":[]}'
run_fake clean-up-after-integration
check "cleanup without a change refused" "missing_--change" "$(jout '.reason')"
check "cleanup without a change reaches no mechanism" "absent" \
  "$([[ -e $FAKE_DIR/cleanup.branch ]] && printf 'called' || printf 'absent')"

# The regression itself: the caller's cwd names the wrong thing, and the named
# change must reach the mechanism anyway. Run from a real repository whose
# current branch is `main`, because a stubbed directory could not tell a
# directory apart from an argument.
CDIR="$tmp/cleanup-cwd"
mkdir -p "$CDIR"
(
  cd "$CDIR" || exit 1
  git init -q -b main .
  git config user.email swe@example.invalid
  git config user.name swe-test
  printf 'x\n' > f.txt
  git add -A
  git commit -q -m 'chore: base'
)
fake_clear
fake_ok cleanup '{"cleaned":["workspace_released"],"risks":[]}'
run_fake_in "$CDIR" clean-up-after-integration --change fix/other-run
check "cleanup is called from a branch that is not the change" "main" "$(git -C "$CDIR" branch --show-current)"
check "cleanup forwards the change, not the cwd's branch" "fix/other-run" "$(cat "$FAKE_DIR/cleanup.branch")"

# A cleanup failure never changes the run's status.
fake_clear
fake_ok cleanup '{"cleaned":["workspace_released"],"risks":["local_branch_delete_failed"]}'
run_fake clean-up-after-integration --change fix/x
check "cleanup risk ok" true "$(jout '.ok')"
check "cleanup risk listed" "local_branch_delete_failed" "$(jout '.risks[0]')"
check "cleanup risks distinct" true "$(jout '.risks != .warnings')"

# Even an injected mechanism failure is demoted to risks.
fake_clear
fake_err cleanup '{"error":"boom"}'
run_fake clean-up-after-integration --change fix/x
check "cleanup mechanism failure ok" true "$(jout '.ok')"
check "cleanup mechanism failure risk" "cleanup_failed" "$(jout '.risks[0]')"

# A session inside the workspace being destroyed is the one hard refusal.
fake_clear
fake_ok cleanup '{"cleaned":[],"risks":[],"session_inside_working_environment":{"move_to":"/somewhere"}}'
run_fake clean-up-after-integration --change fix/x
check "cleanup session reason" "session_inside_working_environment" "$(jout '.reason')"
check "cleanup session move_to" "/somewhere" "$(jout '.move_to')"

echo "=== I2. mutation-scope (real git: base resolution + empty scope) ==="
# Real infrastructure on purpose: every property under test is a git behaviour
# (three-dot diff, symbolic-ref default branch, ref spellings), and a stub would
# only be asserting that the stub agrees with itself.
MREPO="$tmp/mscope"
mkdir -p "$MREPO"
(
  cd "$MREPO" || exit 1
  git init -q -b main .
  git config user.email swe@example.invalid
  git config user.name swe-test
  printf 'def a():\n    pass\n' > app.py
  printf 'readme\n' > README.md
  git add -A
  git commit -q -m 'chore: base'
  # The repository's own declaration of its default branch. This is what makes
  # base resolution a fact lookup rather than a guess. Kept in sync with `main`
  # from here on, so the only diffs measured are the ones a test set up on purpose.
  git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  # A branch that touches exactly one mutable file.
  git checkout -q -b feat
  printf 'def b():\n    pass\n' >> app.py
  git commit -q -am 'feat: work'
)
# Sets RUN_OUT/RUN_RC in the caller's shell. Deliberately not a command
# substitution: a subshell would swallow RUN_OUT and every assertion after it
# would read the previous run's JSON.
MS_RC=0
mscope() {
  RUN_RC=0
  invoke_real "$MREPO" "$tmp/out" "$tmp/err" mutation-scope "$@" || RUN_RC=$?
  MS_RC=$RUN_RC
  RUN_OUT=$(cat "$tmp/out")
}

mscope
check "scope ok" true "$(jout '.ok')"
check "scope base source" "origin_head" "$(jout '.base_source')"
check "scope base name" "main" "$(jout '.base_name')"
check "scope files" "app.py" "$(jout '.files | join(",")')"
has_single_json_line "scope"

# The flag path must win and must be reported as the flag.
mscope --base main
check "scope flag source" "flag" "$(jout '.base_source')"
check "scope flag same ref" "refs/remotes/origin/main" "$(jout '.base')"

# A base name that is not in this tree is an error, never a silent fallback.
mscope --base no-such-branch
check "scope bad base reason" "MUTATION_BASE_UNRESOLVABLE" "$(jout '.reason')"
check "scope bad base exit" 1 "$MS_RC"

# THE load-bearing property. `main` advances while `feat` does not follow, so a
# two-dot diff would report the base's own advance as part of this change and
# the engine would dutifully mutate code this branch never touched.
( cd "$MREPO" && git checkout -q main && printf 'def base_only():\n    pass\n' > base_only.py \
    && git add -A && git commit -q -m 'chore: base advances' \
    && git update-ref refs/remotes/origin/main "$(git rev-parse main)" \
    && git checkout -q feat )
mscope --base main
check "scope excludes base advance" "app.py" "$(jout '.files | join(",")')"
check "scope still scoped" 1 "$(jout '.file_count')"

# An empty scope is the outcome that must never read as a pass.
( cd "$MREPO" && git checkout -q -b docs-only main && printf 'more docs\n' >> README.md \
    && git add -A && git commit -q -m 'docs: prose' && git checkout -q docs-only )
mscope --base main
check "scope empty reason" "MUTATION_SCOPE_EMPTY" "$(jout '.reason')"
check "scope empty exit" 1 "$MS_RC"
check "scope empty no files" "null" "$(jout '.files')"
check "scope empty counted" 1 "$(jout '.changed_files | length')"

# Outside a repository it refuses rather than reporting an empty scope, which
# would be indistinguishable from "this change touches no source".
NOREPO="$tmp/not-a-repo"; mkdir -p "$NOREPO"
RUN_RC=0; invoke_real "$NOREPO" "$tmp/out" "$tmp/err" mutation-scope || RUN_RC=$?; RUN_OUT=$(cat "$tmp/out")
check "scope not a repo" "MUTATION_SCOPE_NOT_A_REPO" "$(jout '.reason')"
check "scope not a repo exit" 1 "$RUN_RC"

# A repository with no resolvable base at all must say so plainly.
NOBASE="$tmp/no-base"; mkdir -p "$NOBASE"
( cd "$NOBASE" && git init -q -b main . && git config user.email s@e.invalid && git config user.name s \
    && git commit -q --allow-empty -m 'chore: base' && git checkout -q -b feat && git commit -q --allow-empty -m 'feat: work' )
RUN_RC=0; invoke_real "$NOBASE" "$tmp/out" "$tmp/err" mutation-scope || RUN_RC=$?; RUN_OUT=$(cat "$tmp/out")
check "scope no base reason" "MUTATION_BASE_UNRESOLVABLE" "$(jout '.reason')"
check "scope no base exit" 1 "$RUN_RC"

echo "=== I3. open-issue (idempotent publication of the approved issue) ==="
# The verb is exercised through the injected mechanism, so the idempotency proof
# does not depend on a tracker being reachable. The mechanism reports facts from
# files, exactly like the real one, and the SECOND call must never reach it: the
# marker the verb wrote into the issue file is the answer.
OI="$tmp/oi"
mkdir -p "$OI"

# A missing issue file is a usage error, not a failed publication.
fake_clear
run_fake open-issue
check "open-issue usage exit" 2 "$RUN_RC"
check "open-issue usage silent" "" "$RUN_OUT"

# Dry run: the payload, and no network.
printf '# Ship the approved issue\n\nStatus: approved\n\nBody references %s directly.\n' "$OI" > "$OI/issue.md"
printf '# Plan\n\nKeep it brief.\n' > "$OI/plan.md"
run_fake open-issue --issue-file "$OI/issue.md" --plan-file "$OI/plan.md" --dry-run
has_single_json_line "open-issue dry-run"
check "open-issue dry-run flag" true "$(jout '.dry_run')"
check "open-issue dry-run title" "Ship the approved issue" "$(jout '.title')"
check "open-issue dry-run title width" true "$(jout '(.title | length) <= 72')"
check "open-issue dry-run plan body" true "$(jout '.body | contains("Keep it brief.")')"
check "open-issue dry-run marker stripped" true "$(jout '.body | contains("Forge-Issue:") | not')"
check "open-issue dry-run state path removed" "no" \
  "$(printf '%s' "$RUN_OUT" | jq -r --arg d "$OI" 'if (.body | contains($d)) then "yes" else "no" end')"
check "open-issue dry-run never publishes" "absent" \
  "$([[ -e $FAKE_DIR/issue.title || -e $FAKE_DIR/issue.body ]] && printf 'called' || printf 'absent')"
check "open-issue dry-run writes no marker" 0 "$(grep -c '^Forge-Issue:' "$OI/issue.md" || true)"

# Long titles are capped at 72 columns, on one line.
long_title=$(printf 'word %.0s' {1..40})
run_fake open-issue --issue-file "$OI/issue.md" --dry-run --title "$long_title"
check "open-issue title capped" 72 "$(jout '.title | length')"

# First publication: the mechanism is called once and the marker is written.
fake_clear
fake_ok issue '{"ok":true,"forge":"github","number":11,"url":"https://example.invalid/o/r/issues/11"}'
run_fake open-issue --issue-file "$OI/issue.md"
has_single_json_line "open-issue create"
check "open-issue create ok" true "$(jout '.ok')"
check "open-issue create existing" false "$(jout '.existing')"
check "open-issue create number" 11 "$(jout '.issue.number')"
check "open-issue create url" "https://example.invalid/o/r/issues/11" "$(jout '.issue.url')"
check "open-issue create title forwarded" "Ship the approved issue" "$(cat "$FAKE_DIR/issue.title")"
check "open-issue create body forwarded" "yes" \
  "$(grep -q 'Status: approved' "$FAKE_DIR/issue.body" && printf 'yes' || printf 'no')"
check "open-issue marker written" 1 "$(grep -c '^Forge-Issue: 11 ' "$OI/issue.md" || true)"

# Resume: the second call answers with the existing item and reaches nothing.
rm -f "$FAKE_DIR/issue.title" "$FAKE_DIR/issue.body"
run_fake open-issue --issue-file "$OI/issue.md"
has_single_json_line "open-issue resume"
check "open-issue resume existing" true "$(jout '.existing')"
check "open-issue resume number" 11 "$(jout '.issue.number')"
check "open-issue resume never republished" "absent" \
  "$([[ -e $FAKE_DIR/issue.title ]] && printf 'called' || printf 'absent')"
check "open-issue resume no duplicate marker" 1 "$(grep -c '^Forge-Issue:' "$OI/issue.md" || true)"

# A marker a human mangled is a refusal, never a duplicate.
printf '# Mangled\n\nForge-Issue: not-a-number\n' > "$OI/bad.md"
run_fake open-issue --issue-file "$OI/bad.md"
check "open-issue bad marker reason" "ISSUE_MARKER_INVALID" "$(jout '.reason')"
check "open-issue bad marker exit" 1 "$RUN_RC"

# An unreachable tracker is a failure the caller can demote to a warning; the
# file is left unmarked so a later run can retry.
printf '# Retry later\n\nbody\n' > "$OI/fail.md"
fake_clear
fake_err issue '{"error":"ISSUE_CREATE_FAILED"}'
run_fake open-issue --issue-file "$OI/fail.md"
check "open-issue publish failure reason" "ISSUE_CREATE_FAILED" "$(jout '.reason')"
check "open-issue publish failure exit" 1 "$RUN_RC"
check "open-issue publish failure unmarked" 0 "$(grep -c '^Forge-Issue:' "$OI/fail.md" || true)"

# A mechanism that dies silently is still a failure, never a success.
fake_clear
fake_err issue ''
run_fake open-issue --issue-file "$OI/fail.md"
check "open-issue unreadable mechanism" "ISSUE_CREATE_FAILED" "$(jout '.reason')"

# --- the real mechanism, against the forge --------------------------------
# The block above proves the verb's contract against an injected mechanism. The
# block below proves the concrete implementation actually produces those facts:
# URL/number parsing, argv shapes, the payload on a resumed dry run, the UTF-8
# title cap, and the self-hosted host override.
unset GITLAB_HOST
REAL_GH="$tmp/oi-real-gh"; mk_repo "$REAL_GH" "https://github.com/example/repo.git"
GH_CALLS="$STUBBIN/.gh_issue_calls"
GLAB_ARGV="$STUBBIN/.glab_issue_argv"
gh_calls() { if [[ -f $GH_CALLS ]]; then grep -c . "$GH_CALLS"; else printf 0; fi; }

# 1. The ordinary case: the URL identifies the item, and the marker makes the
# second call a local answer instead of a second issue.
rm -f "$GH_CALLS"
printf '# Real GitHub issue\n\nBody of the real issue.\n' > "$tmp/real-gh.md"
run_real_in "$REAL_GH" open-issue --issue-file "$tmp/real-gh.md"
check "real gh ok" true "$(jout '.ok')"
check "real gh number" 42 "$(jout '.issue.number')"
check "real gh url" "https://github.com/example/repo/issues/42" "$(jout '.issue.url')"
check "real gh marker once" 1 "$(grep -c '^Forge-Issue: 42 ' "$tmp/real-gh.md" || true)"
check "real gh forge called once" 1 "$(gh_calls)"
run_real_in "$REAL_GH" open-issue --issue-file "$tmp/real-gh.md"
check "real gh resume existing" true "$(jout '.existing')"
check "real gh resume no second call" 1 "$(gh_calls)"

# 2. A URL-less success still publishes. `✓ Created issue #42` names the item;
# reading only the URL would report a failure and the next resume would open a
# duplicate.
rm -f "$GH_CALLS"
printf '# URL-less issue\n\nBody.\n' > "$tmp/real-nourl.md"
export ISSUE_OUTPUT='✓ Created issue #42'
run_real_in "$REAL_GH" open-issue --issue-file "$tmp/real-nourl.md"
unset ISSUE_OUTPUT
check "real gh no-url ok" true "$(jout '.ok')"
check "real gh no-url number" 42 "$(jout '.issue.number')"
check "real gh no-url url null" null "$(jout '.issue.url')"
check "real gh no-url marker" "Forge-Issue: 42" \
  "$(sed -n 's/[[:space:]]*$//; /^Forge-Issue:/p' "$tmp/real-nourl.md")"
check "real gh no-url forge called once" 1 "$(gh_calls)"
run_real_in "$REAL_GH" open-issue --issue-file "$tmp/real-nourl.md"
check "real gh no-url resume existing" true "$(jout '.existing')"
check "real gh no-url resume no second call" 1 "$(gh_calls)"

# 3. GitLab carries the description as a file, never in argv.
REAL_GL="$tmp/oi-real-glab"; mk_repo "$REAL_GL" "https://gitlab.com/example/repo.git"
rm -f "$GLAB_ARGV"
printf '# Real GitLab issue\n\nGLAB_BODY_SENTINEL\n' > "$tmp/real-glab.md"
run_real_in "$REAL_GL" open-issue --issue-file "$tmp/real-glab.md"
check "real glab ok" true "$(jout '.ok')"
check "real glab number" 7 "$(jout '.issue.number')"
check "real glab url" "https://gitlab.com/example/repo/-/issues/7" "$(jout '.issue.url')"
check "real glab description as file" yes \
  "$(grep -q -- '--description-file' "$GLAB_ARGV" && printf yes || printf no)"
check "real glab body not in argv" no \
  "$(grep -q 'GLAB_BODY_SENTINEL' "$GLAB_ARGV" && printf yes || printf no)"
check "real glab marker once" 1 "$(grep -c '^Forge-Issue: 7 ' "$tmp/real-glab.md" || true)"

# 4. A resumed --dry-run still owes the caller the payload; the marker replaces
# the network call, not the answer.
run_real_in "$REAL_GH" open-issue --issue-file "$tmp/real-gh.md" --dry-run
check "real resume dry-run flag" true "$(jout '.dry_run')"
check "real resume dry-run existing" true "$(jout '.existing')"
check "real resume dry-run title" "Real GitHub issue" "$(jout '.title')"
check "real resume dry-run body" true "$(jout '(.body | length) > 0')"
check "real resume dry-run no call" 1 "$(gh_calls)"
# A resumed dry run must not fail on a plan file that is gone.
run_real_in "$REAL_GH" open-issue --issue-file "$tmp/real-gh.md" \
  --plan-file "$tmp/absent-plan.md" --dry-run
check "real resume dry-run missing plan ok" true "$(jout '.ok')"

# 5. The 72-column cap counts CODEPOINTS, so an all-accented title is still
# valid UTF-8 under the C locale. A byte slice cuts a character in half.
printf '# A%s\n' "$(printf 'á%.0s' {1..80})" > "$tmp/real-accent.md"
export LC_ALL=C
run_real_in "$REAL_GH" open-issue --issue-file "$tmp/real-accent.md" --dry-run
unset LC_ALL
check "real accent title capped" 72 "$(jout '.title | length')"
check "real accent title multibyte" true "$(jout '.title | utf8bytelength > 72')"
check "real accent no replacement char" 0 \
  "$(jout '[.title | explode[] | select(. == 65533)] | length')"
check "real accent output is utf-8" valid \
  "$(printf '%s' "$RUN_OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && printf valid || printf invalid)"

# 6. A self-hosted instance lives on an address that does not say "gitlab".
# GITLAB_HOST is the operator's word for it; without it the host is unknown.
UNK="$tmp/oi-unknown"; mk_repo "$UNK" "git@git.company.com:o/r.git"
rm -f "$GLAB_ARGV"
printf '# Self-hosted issue\n\nBody.\n' > "$tmp/unknown-host.md"
export GITLAB_HOST=gitlab.company.com
run_real_in "$UNK" open-issue --issue-file "$tmp/unknown-host.md"
unset GITLAB_HOST
check "self-hosted glab ok" true "$(jout '.ok')"
check "self-hosted glab number" 7 "$(jout '.issue.number')"
check "self-hosted glab path taken" yes "$([[ -f $GLAB_ARGV ]] && printf yes || printf no)"
printf '# Unsupported issue\n\nBody.\n' > "$tmp/unsupported-host.md"
run_real_in "$UNK" open-issue --issue-file "$tmp/unsupported-host.md"
check "unknown forge reason" "ISSUE_MECHANISM_UNSUPPORTED" "$(jout '.reason')"
check "unknown forge exit" 1 "$RUN_RC"

echo "=== J. vocabulary guard (new surface + agent prompts) ==="
# Where the agent prompts live. RESOLVED, never assumed: this used to be a
# literal `../../../dot_config/opencode/agents` relative to the install root,
# which silently pointed at a path that does not exist on this machine, so the
# prompt guard reported "missing" and the one check that could catch mechanism
# vocabulary leaking into the agent surface never ran. A guard that cannot find
# its subject has to say so loudly, not fail as a pass.
#
# The prompt set is SPLIT across two trees on a pi install: the orchestrator
# prompt lives in the pi prompts dir, the per-agent prompts in the agents
# extension. A single-directory assumption reports four "missing" failures for
# four files that all exist, so every file is resolved on its own over a list of
# roots and the label names the file that was actually read.
#
# Order: explicit override, then the opencode config dir (XDG), then the
# dotfiles checkout layout, then the pi trees.
AGENT_DIRS=()
[[ -n ${SWE_AGENTS_DIR:-} ]] && AGENT_DIRS+=("$SWE_AGENTS_DIR")
AGENT_DIRS+=(
  "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/agents"
  "$HOME/dot_config/opencode/agents"
  "$HOME/.pi/agent/prompts"
  "$HOME/.pi/agent/extensions/agents/resources/workflow-agents/swe"
)
AGENTS=''
for cand in "${AGENT_DIRS[@]}"; do
  [[ -d $cand ]] || continue
  AGENTS=${AGENTS:+$AGENTS:}$cand
done
if [[ -z $AGENTS ]]; then
  bad "guard: agents dir not found (set SWE_AGENTS_DIR)"
fi

# The change.manifest verb column.
if printf '%s\n' "$dverbs" | grep -Eq "$SURFACE_FORBIDDEN"; then
  bad "guard: manifest verb column"
  printf '%s\n' "$dverbs" | grep -En "$SURFACE_FORBIDDEN" | sed 's/^/      /'
else
  ok "guard: manifest verb column"
fi

# reason literals in the domain modules (mechanism implementation excluded).
reasons=$(grep -rhoE 'fail "[^"]+"' "$ROOT/lib/change" --include='*.sh' --exclude-dir=mechanism \
  | sed -E 's/^fail "//; s/"$//' | sort -u)
if printf '%s\n' "$reasons" | grep -Eq "$SURFACE_FORBIDDEN"; then
  bad "guard: reason literals"
  printf '%s\n' "$reasons" | grep -En "$SURFACE_FORBIDDEN" | sed 's/^/      /'
else
  ok "guard: reason literals"
fi

# emitted JSON keys in the domain modules.
keys=$(grep -rhoE '\b[a-z][a-z0-9_]*:' "$ROOT"/lib/change/*.sh | sed 's/:$//' | sort -u)
if printf '%s\n' "$keys" | grep -Eq "$SURFACE_FORBIDDEN"; then
  bad "guard: emitted JSON keys"
  printf '%s\n' "$keys" | grep -En "$SURFACE_FORBIDDEN" | sed 's/^/      /'
else
  ok "guard: emitted JSON keys"
fi

# the four agent prompts (full text). A missing directory must NOT count as four
# passing checks: that is the failure mode that hid this guard in the first
# place. Absent prompts are reported as their own failure, never as clean.
if [[ -n $AGENTS ]]; then
  # WHICH file was checked goes in the label. The source tree and the installed
  # tree are different files with the same names, so this guard is otherwise free
  # to report green on the installed copy while the source — the file an edit
  # actually changes — was never read.
  printf '      (agentes: %s)\n' "$AGENTS"
  for p in swe.md swe-executor.md swe-reviewer.md swe-closer.md; do
    found=''
    for d in "${AGENT_DIRS[@]}"; do
      [[ -f "$d/$p" ]] && { found="$d/$p"; break; }
    done
    if [[ -z $found ]]; then
      bad "guard: prompt $p (not found under: $AGENTS)"
      continue
    fi
    if grep -Eq "$PROMPT_FORBIDDEN" "$found"; then
      bad "guard: prompt $p ($found)"
      grep -En "$PROMPT_FORBIDDEN" "$found" | sed 's/^/      /'
    else
      ok "guard: prompt $p"
    fi
  done
  # The guard is only worth anything if it can still find its subject.
  check "guard: agents dir resolved" true "$([[ -n $AGENTS ]] && echo true || echo false)"
fi

# Meta: the guard must actually find things and must actually trip on leakage.
check "guard: keys extracted" true "$([[ -n $keys ]] && echo true || echo false)"
check "guard: reasons extracted" true "$([[ -n $reasons ]] && echo true || echo false)"
if printf 'gh pr draft\n' | grep -Eq "$PROMPT_FORBIDDEN"; then ok "guard self-test prompt leakage"; else bad "guard self-test prompt leakage"; fi
if printf 'VERIFICATION_UNKNOWN\nINTEGRATION_BASE_UNKNOWN\n' | grep -Eq "$SURFACE_FORBIDDEN"; then bad "guard self-test surface false positive"; else ok "guard self-test surface false positive"; fi

echo "=== K. the lens set and the lens registry agree (cross-repo seam) ==="

# The driver plans the axes (`REVIEW_LENSES` here) and the reviewer reads its
# checklist from the agent tree (`extensions/agents/lenses/<name>.md`). Two
# repos, two facts, one contract: a lens the driver names and the registry does
# not have is a reviewer with no assignment. The check SKIPs when there is no
# agent tree on this machine, and it is never allowed to pass vacuously.
lens_list=$(awk -F"'" '/^readonly REVIEW_LENSES=/ {print $2}' "$ROOT/lib/change/review.sh")
lens_agents="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/agents"
check "lens list extracted" "behavior,code,security,performance,docs" "$lens_list"
if [[ -d $lens_agents/lenses ]]; then
  while IFS= read -r lens; do
    [[ -n $lens ]] || continue
    if [[ $lens == behavior ]]; then ok "lens behavior -> its own reviewer agent"; continue; fi
    if [[ -f "$lens_agents/lenses/$lens.md" ]]; then ok "lens fragment: $lens"; else bad "lens fragment: $lens (missing in $lens_agents/lenses)"; fi
  done < <(printf '%s\n' "$lens_list" | tr ',' '\n')
  extra=$(ls "$lens_agents/lenses" 2>/dev/null | sed 's/\.md$//' | while read -r f; do case ",$lens_list," in *",$f,"*) ;; *) printf '%s\n' "$f" ;; esac; done)
  check "no fragment without a lens" "" "$extra"
else
  echo "    SKIP  lens registry (no agent tree at $lens_agents)"
fi

echo
printf '%d/%d passed\n' "$pass" "$((pass + fail))"
[[ $fail -eq 0 ]]
