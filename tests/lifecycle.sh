#!/usr/bin/env bash
# lifecycle.sh — integration contract for the real worktree lifecycle, which
# contract.sh cannot reach (it deliberately runs in a non-git directory).
#
# Discipline is the same as contract.sh, with one addition. Every step is run
# twice — once against the frozen baseline monolith and once against the new
# facade — in two isolated throwaway repositories, and the normalized stdout +
# exit code must be IDENTICAL. On top of that, the facade's run is checked
# against absolute invariants (worktree really exists, really is linked, the
# branch really survives a remove, ...). Differential alone would pass if both
# binaries were equally broken; absolute checks alone would not prove the
# refactor preserved behavior. Both together do.
#
# Isolation: two repos both named `repo` (under <root>/base and <root>/new), so
# normalizing the two distinct parent prefixes to <X> is enough to compare. The
# visual surface is forced off (HERDR_ENV empty) so view_id is always "".
#
# Run with: bash tests/lifecycle.sh   (exits non-zero if any case fails)

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT_DIR=$(dirname "$HERE")
ENTRY="$ROOT_DIR/swe.sh"
BASE="$HERE/baseline/swe-workspace-manager.sh"

# git + wt are both required for the lifecycle to be meaningful; without them
# there is nothing to test, so this is a SKIP, not a failure.
if ! command -v git >/dev/null 2>&1 || ! command -v wt >/dev/null 2>&1; then
  echo "SKIP  lifecycle: requires git + wt"
  exit 0
fi

# The baseline is committed; its absence is a real failure, not a skip.
if [[ ! -f $BASE ]]; then
  echo "FAIL  lifecycle: baseline fixture missing at $BASE"
  exit 1
fi

# Determinism: no prompts, no pagers, no visual surface, and no user/global git
# config (whose hooks would otherwise run inside the throwaway repos).
export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat CI=true
export HERDR_ENV=
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
check() { # check <label> <expected> <actual>
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}

# Step labels, kept in sync with the scenario below.
labels=()
labels[1]=ensure-create
labels[2]=ensure-reuse
labels[3]=planning-stability
labels[4]=resolve-inside
labels[5]=resolve-wrong-location
labels[6]=remove-inside-refused
labels[7]=remove-force-delete
labels[8]=remove-idempotent
labels[9]=close-no-view

root=$(mktemp -d "${TMPDIR:-/tmp}/swe-lifecycle.XXXXXX")

# Cleanup must never mask a failure: remember the status, tear everything down
# (worktrees first, while their repos still exist), then re-exit with it.
cleanup() {
  local rc=$?
  local r w
  for r in "$root/base/repo" "$root/new/repo"; do
    [[ -d $r ]] || continue
    while IFS= read -r w; do
      [[ -n $w && $w != "$r" ]] || continue
      git -C "$r" worktree remove --force "$w" >/dev/null 2>&1 || true
    done < <(git -C "$r" worktree list --porcelain 2>/dev/null \
               | awk '/^worktree /{print $2}')
  done
  rm -rf "$root"
  exit "$rc"
}
trap cleanup EXIT

build_repo() { # build_repo <dir>
  local dir=$1
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init -q -b main .
    git config user.email swe@example.invalid
    git config user.name swe-test
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -qm init
  )
}

build_repo "$root/base/repo"
build_repo "$root/new/repo"

# run_step <bin> <cwd> <step> [args...] — runs one command, captures stdout and
# exit code, and persists both so the two scenarios can be compared stepwise.
# stderr is dropped on purpose: it is progress/tool chatter, not the contract.
OUTDIR=''
STEP_OUT=''
STEP_RC=0
run_step() {
  local bin=$1 cwd=$2 step=$3
  shift 3
  STEP_OUT=$(cd "$cwd" && bash "$bin" "$@" 2>/dev/null)
  STEP_RC=$?
  printf '%s\n' "$STEP_OUT" >"$OUTDIR/step$step.out"
  printf '%s\n' "$STEP_RC" >"$OUTDIR/step$step.rc"
}
jqout() { printf '%s\n' "$STEP_OUT" | jq -r "$1"; }

# scenario <bin> <repo> <outdir> <do_asserts:0|1>
# Runs the same ordered lifecycle for one binary in one repo. Absolute
# assertions run only for the facade run (the baseline run exists to be compared
# against); the paths it derives are needed in both runs to drive later steps.
scenario() {
  local bin=$1 repo=$2 asserts=$4
  OUTDIR=$3
  mkdir -p "$OUTDIR"

  local branch=feat/demo
  local primary_real
  primary_real=$(cd "$repo" && pwd -P)
  local wt='' pd=''

  # 1 — create the working environment for a fresh branch. Everything downstream
  #     depends on it being real and linked, so that is checked, not assumed.
  run_step "$bin" "$repo" 1 ensure --type feature --slug demo
  # The frozen baseline still names the field `worktree`; the facade names it
  # `workingEnvironment`. Both are read here because this setup drives BOTH runs,
  # while the assertions below only ever run against the facade.
  wt=$(jqout '.workingEnvironment // .worktree')
  pd=$(jqout .planning_dir)
  if [[ $asserts == 1 ]]; then
    check "step1 $branch ok" true "$(jqout .ok)"
    check "step1 ensure-create branch" "$branch" "$(jqout .branch)"
    check "step1 ensure-create reused" false "$(jqout .reused)"
    check "step1 ensure-create view_open" false "$(jqout .view_open)"
    check "step1 ensure-create view_id" "" "$(jqout .view_id)"
    check "step1 ensure-create warnings" 0 "$(jqout '.warnings|length')"
    check "step1 ensure-create workingEnvironment" "$wt" "$(jqout .workingEnvironment)"
    if [[ -n $wt && -d $wt ]]; then
      ok "step1 ensure-create working-environment-dir"
    else
      bad "step1 ensure-create working-environment-dir ($wt)"
    fi
    # A linked worktree's --git-dir lives under the primary's .git/worktrees/, so
    # it differs from --git-common-dir; a plain checkout would have them equal.
    local gd gcd
    gd=$(git -C "$wt" rev-parse --git-dir 2>/dev/null)
    gcd=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)
    check "step1 ensure-create linked" "true" \
      "$([[ -n $gd && $gd != "$gcd" ]] && echo true || echo false)"
    check "step1 ensure-create HEAD-branch" "$branch" \
      "$(git -C "$wt" branch --show-current 2>/dev/null)"
    check "step1 ensure-create planning_dir" "$wt/docs/planning/0001-feature-demo" "$pd"
    check "step1 ensure-create location.required" "$wt" "$(jqout .session_location.required)"
    check "step1 ensure-create location.match" false "$(jqout .session_location.match)"
    # The run declares its integration base: the checkout ensure was invoked
    # from (main here), captured before the working environment existed, and
    # stored where every later verb reads it — nobody has to pass it around.
    check "step1 ensure-create base_branch" "main" "$(jqout .base_branch)"
    local runbase
    runbase=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)/swe-run-base
    check "step1 ensure-create run-base-declared" "main" "$(head -n1 "$runbase" 2>/dev/null)"
  fi

  local wt1=$wt pd1=$pd

  # 2 — ensure is idempotent: the same branch maps back to the same working
  #     environment and the same planning directory, so a resumed run never splits
  #     artifacts.
  run_step "$bin" "$repo" 2 ensure --type feature --slug demo
  if [[ $asserts == 1 ]]; then
    check "step2 ensure-reuse reused" true "$(jqout .reused)"
    check "step2 ensure-reuse workingEnvironment" "$wt1" "$(jqout .workingEnvironment)"
    check "step2 ensure-reuse planning_dir" "$pd1" "$(jqout .planning_dir)"
    # A reused run reports the SAME declaration: the base is decided once with
    # type/slug and never re-derived, exactly like the branch itself.
    check "step2 ensure-reuse base_branch" "main" "$(jqout .base_branch)"
  fi

  # 3 — the documented stability contract: an EXISTING planning directory for
  #     this type+slug wins over a fresh number. If it did not, 0002-… would
  #     appear here and the planner's artifacts would be orphaned.
  mkdir -p "$pd1"
  run_step "$bin" "$repo" 3 ensure --type feature --slug demo
  if [[ $asserts == 1 ]]; then
    check "step3 planning-stability planning_dir" "$pd1" "$(jqout .planning_dir)"
    check "step3 planning-stability reused" true "$(jqout .reused)"
  fi

  # 4 — resolve from INSIDE the working environment is the happy path: it must
  #     hand back the run's paths and admit it was not called with --from-anywhere.
  run_step "$bin" "$wt1" 4 resolve --branch "$branch"
  if [[ $asserts == 1 ]]; then
    check "step4 resolve-inside ok" true "$(jqout .ok)"
    check "step4 resolve-inside workingEnvironment" "$wt1" "$(jqout .workingEnvironment)"
    check "step4 resolve-inside planning_dir" "$pd1" "$(jqout .planning_dir)"
    check "step4 resolve-inside from_anywhere" false "$(jqout .from_anywhere)"
  fi

  # 5 — the gate: from the primary checkout, resolve must REFUSE and say where
  #     the session has to move. A gate that misfires is worse than none.
  run_step "$bin" "$repo" 5 resolve --branch "$branch"
  if [[ $asserts == 1 ]]; then
    check "step5 resolve-wrong-location ok" false "$(jqout .ok)"
    check "step5 resolve-wrong-location reason" wrong_location "$(jqout .reason)"
    check "step5 resolve-wrong-location move_to" "$wt1" "$(jqout .move_to)"
  fi

  # 6 — data safety: removing the working environment from inside it would kill
  #     the caller's own cwd, so it must be refused (not bypassable) and the
  #     directory must STILL be on disk afterwards.
  run_step "$bin" "$wt1" 6 remove --branch "$branch"
  if [[ $asserts == 1 ]]; then
    check "step6 remove-inside-refused ok" false "$(jqout .ok)"
    check "step6 remove-inside-refused reason" session_inside_working_environment \
      "$(jqout .reason)"
    check "step6 remove-inside-refused move_to" "$primary_real" "$(jqout .move_to)"
    if [[ -d $wt1 ]]; then
      ok "step6 remove-inside-refused working-environment-survives"
    else
      bad "step6 remove-inside-refused working-environment-survives ($wt1 gone)"
    fi
  fi

  # 7 — the real removal, from a safe cwd, forcing past the unmerged-commit guard.
  #     The working environment goes; the branch must stay (the closer deletes it
  #     later).
  run_step "$bin" "$repo" 7 remove --branch "$branch" --force-delete
  if [[ $asserts == 1 ]]; then
    check "step7 remove-force-delete ok" true "$(jqout .ok)"
    check "step7 remove-force-delete removed" true "$(jqout .removed)"
    if [[ -e $wt1 ]]; then
      bad "step7 remove-force-delete working-environment-gone (still at $wt1)"
    else
      ok "step7 remove-force-delete working-environment-gone"
    fi
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      ok "step7 remove-force-delete branch-survives"
    else
      bad "step7 remove-force-delete branch-survives (branch deleted)"
    fi
  fi

  # 8 — idempotent remove: the goal state is "no working environment for this
  #     branch", so a second call is success with removed:false, not an error.
  run_step "$bin" "$repo" 8 remove --branch "$branch" --force-delete
  if [[ $asserts == 1 ]]; then
    check "step8 remove-idempotent ok" true "$(jqout .ok)"
    check "step8 remove-idempotent removed" false "$(jqout .removed)"
    check "step8 remove-idempotent reason" working_environment_not_found \
      "$(jqout .reason)"
  fi

  # 9 — close with no view id is a no-op success (the surface is optional).
  run_step "$bin" "$repo" 9 close
  if [[ $asserts == 1 ]]; then
    check "step9 close-no-view ok" true "$(jqout .ok)"
    check "step9 close-no-view closed" false "$(jqout .closed)"
    check "step9 close-no-view reason" no_view "$(jqout .reason)"
  fi
}

echo "=== lifecycle: baseline vs swe (2 isolated repos) ==="
scenario "$BASE" "$root/base/repo" "$root/base-out" 0
scenario "$ENTRY" "$root/new/repo" "$root/new-out" 1

# Normalize only the two distinct parent prefixes; both repos are named `repo`,
# so everything else (checkout name, planning dir) is directly comparable.
#
# Plus the ONE intended divergence from the frozen baseline: the JSON contract
# was renamed from `worktree` to `workingEnvironment` (and its reasons with it)
# so the contract names the run, not the mechanism. The baseline stays frozen as
# the historical reference — regenerating it from the facade would make this
# differential compare the new implementation against a copy of itself and prove
# nothing. Mapping only these strings keeps the differential doing its real job:
# catching any OTHER behavior drift (paths, branches, ordering, warnings, exits).
# Reason strings are mapped individually, in order, because a blanket s/worktree/
# would produce the wrong casing for snake_case reasons.
#
# And the ONE additive field: `base_branch` (the integration base `ensure`
# declares for the run) is stripped from both sides — the frozen baseline cannot
# know a field added after it was frozen, and hiding it here is what lets the
# absolute assertions below prove it exists and is correct on the facade run.
# It is always comma-suffixed in the output (never the last key), so removing it
# leaves both strings byte-identical.
norm_paths() {
  sed -e "s#$root/base#<X>#g" -e "s#$root/new#<X>#g" \
      -e 's/"base_branch":"[^"]*",//' \
      -e 's/,"git":[a-z]*//g' \
      -e 's/,"forge":[a-z]*//g' \
      -e 's/,"in_place":[a-z]*//g' \
      -e 's/,"environment":"[a-z]*"//g' \
      -e 's/no_worktree_for_branch/no_working_environment_for_branch/g' \
      -e 's/session_inside_worktree/session_inside_working_environment/g' \
      -e 's/worktree_not_found/working_environment_not_found/g' \
      -e 's/detached_worktree_left_in_place_/detached_working_environment_left_in_place_/g' \
      -e 's/forced_past_dirty_worktree/forced_past_dirty_working_environment/g' \
      -e 's/dirty_worktree/dirty_working_environment/g' \
      -e 's/already_in_linked_worktree/already_in_working_environment/g' \
      -e 's/current_worktree/current_workingEnvironment/g' \
      -e 's/not_a_git_work_tree/not_a_git_repository/g' \
      -e 's/"worktree":/"workingEnvironment":/g' \
      -e 's/from inside its worktree;/from inside its working environment;/g' \
      -e 's/out of the worktree first,/out of the working environment first,/g' "$1"
}

echo "=== differential (normalized stdout + exit code) ==="
for n in 1 2 3 4 5 6 7 8 9; do
  bo=$(norm_paths "$root/base-out/step$n.out")
  no=$(norm_paths "$root/new-out/step$n.out")
  brc=$(cat "$root/base-out/step$n.rc")
  nrc=$(cat "$root/new-out/step$n.rc")
  if [[ $bo == "$no" && $brc == "$nrc" ]]; then
    ok "step$n ${labels[$n]} diff"
  else
    bad "step$n ${labels[$n]} diff (exit base=$brc new=$nrc)"
    printf '      base=[%s]\n      new =[%s]\n' "$bo" "$no"
  fi
done

echo
printf '%d/%d passed\n' "$pass" "$((pass + fail))"
[[ $fail -eq 0 ]]
