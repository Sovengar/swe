#!/usr/bin/env bash
# swe-workspace-manager.sh — deterministic worktree lifecycle for the swe pipeline.
#
# Harness-agnostic on purpose: the swe orchestrator calls this instead of assembling
# `wt`/`herdr` sequences itself, so a small model cannot skip or reorder a step.
# Speaks only to `wt`, `herdr`, `git` and `jq` — nothing harness-specific.
#
# Herdr (and worktrunk) are implementation details of this script on purpose: the
# agents that call it never learn they exist. The JSON contract below is the whole
# surface they see, and it is deliberately free of backend names.
#
# Usage:
#   swe-workspace-manager.sh ensure --type <type> --slug <slug> [--base <ref>]
#   swe-workspace-manager.sh location [--expect <dir>]
#   swe-workspace-manager.sh resolve --branch <branch> [--from-anywhere]
#   swe-workspace-manager.sh remove --branch <branch> [--worktree <path>]
#                                   [--base <ref>] [--force] [--force-delete]
#   swe-workspace-manager.sh close --view <view_id>
#
# Contract:
#   stdout: exactly one line of JSON, always with an "ok" boolean. Nothing else.
#   exit 0: ok=true.  exit 1: ok=false (reason inside the JSON).  exit 2: usage error.
#   Progress and tool chatter go to stderr, so a caller can read stdout unfiltered.
#
# ensure   → {ok, branch, worktree, view_id, planning_dir, view_open, reused,
#             session_location, warnings}
# location → {ok, match?, session_dir, expected?, harness}
# resolve  → {ok, branch, worktree, planning_dir, harness, from_anywhere}
# remove   → {ok, removed, branch, worktree, view_id, warnings}
# close    → {ok, closed, reason, warnings}
#
# session_location is the session-directory contract, and it exists because a
# child session is born wherever its parent lives (the child copies the parent's
# location at creation time — verified: a subagent shell runs with cwd = the
# session directory). So the ONLY way to have children start inside the worktree
# is for the orchestrator's own session to be moved there first.
#
# This script cannot do that move: relocating a live session is a harness
# capability, not a filesystem operation (opencode: the session_move tool; codex
# and pi: not available in-session at all). So `ensure` creates the worktree and
# reports where the session currently is, and the orchestrator relocates and then
# re-checks with `location --expect <worktree>` BEFORE creating any child. A run
# that skips the re-check can spawn children into the old directory.
#
# view_id / view_open describe an optional visual surface attached to the worktree
# so the user can watch the run. It is presentation only: every subcommand still
# succeeds with view_id="" when no surface backend is available.

set -euo pipefail

readonly VALID_TYPES="feature fix refactor chore docs"
# The planning directory and the git branch do not use the same word: the
# directory says `feature`, the branch says `feat` (see swe.md branch rules).
readonly SLUG_RE='^[a-z0-9]+(-[a-z0-9]+)*$'

branch_prefix_for() {
  case $1 in
    feature) printf 'feat' ;;
    fix|refactor|chore|docs) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# Inverse of branch_prefix_for, so a child can name its run from the branch
# alone. Needed because `resolve` is handed a branch and nothing else: the fewer
# facts a child carries around, the fewer ways it can carry the wrong ones.
type_from_prefix() {
  case $1 in
    feat) printf 'feature' ;;
    fix|refactor|chore|docs) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

usage() {
  cat >&2 <<'EOF'
Usage:
  swe-workspace-manager.sh ensure --type <feature|fix|refactor|chore|docs> --slug <slug> [--base <ref>]
  swe-workspace-manager.sh location [--expect <dir>]
  swe-workspace-manager.sh resolve --branch <branch> [--from-anywhere]
  swe-workspace-manager.sh remove --branch <branch> [--worktree <path>]
                                   [--base <ref>] [--force] [--force-delete]
  swe-workspace-manager.sh close --view <view_id>

Contract:
  stdout: exactly one line of JSON, always with an "ok" boolean. Nothing else.
  exit 0: ok=true.  exit 1: ok=false (reason inside the JSON).  exit 2: usage error.
  Progress and tool chatter go to stderr, so a caller can read stdout unfiltered.
EOF
  exit 2
}

# --- json output ------------------------------------------------------------

warn=()

warnings_json() {
  if [[ ${#warn[@]} -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${warn[@]}" | jq -R . | jq -sc .
  fi
}

# Callers pass a JSON object to enrich the failure, so the caller of this script
# gets the context needed to act (which path, which branch, how many commits)
# instead of a bare reason string.
fail() { # fail <reason> [json-object]
  local reason=$1
  local extra=${2-}
  # Note: the default must not be written as ${2:-'{}'}; the quotes survive the
  # expansion and jq then rejects 'not json' instead of printing the failure.
  [[ -n $extra ]] || extra='{}'
  jq -nc --arg reason "$reason" --argjson extra "$extra" \
    '{ok: false, reason: $reason} + $extra + {warnings: []}'
  exit 1
}

# --- environment probes -----------------------------------------------------

# The visual surface is optional. When it is unavailable every subcommand still
# does its real job; view_id comes back empty and the caller carries on.
view_backend() { [[ ${HERDR_ENV:-} == 1 ]] && command -v herdr >/dev/null 2>&1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "missing_dependency_$1"; }

is_linked_worktree() {
  [[ "$(git rev-parse --git-dir 2>/dev/null)" != "$(git rev-parse --git-common-dir 2>/dev/null)" ]]
}

# Path of the primary checkout, even when invoked from inside a linked worktree.
primary_checkout() {
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$(dirname "$common")" && pwd -P)
}

# Canonical worktree path checked out at BRANCH, empty when there is none.
# git worktree list --porcelain is used on purpose: `wt list --format=json` is
# mid-migration between two schemas and `jq select` breaks on the array form.
worktree_for_branch() {
  local branch=$1 path=''
  while read -r line; do
    case $line in
      'worktree '*) path=${line#worktree } ;;
      "branch refs/heads/$branch") printf '%s\n' "$path"; return 0 ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  return 1
}

# Paths of the worktrees whose HEAD is detached, one per line. They are the blind
# spot of worktree_for_branch: a detached worktree is not on any branch, so a
# lookup by branch cannot see it even though it is still holding a directory and
# possibly the only copy of a commit. Non-zero when there are none.
detached_worktrees() {
  local line path='' found=false
  while read -r line; do
    case $line in
      'worktree '*) path=${line#worktree } ;;
      detached)
        [[ -n $path ]] || continue
        printf '%s\n' "$path"
        found=true
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  [[ $found == true ]]
}

# --- view backend plumbing (never surfaced to callers) ----------------------

_view_repo_root() {
  local root
  root=$(herdr worktree list --cwd "$PWD" --json 2>/dev/null \
    | jq -r '.result.source.repo_root // empty' 2>/dev/null) || root=''
  [[ -n $root ]] && { printf '%s\n' "$root"; return 0; }
  primary_checkout
}

# View already attached to PATH, empty when the worktree is not visible yet.
_view_on() {
  local wt=$1
  herdr worktree list --cwd "$(_view_repo_root)" --json 2>/dev/null \
    | jq -r --arg p "$wt" \
        '.result.worktrees[]? | select(.path == $p) | .open_workspace_id // empty' \
    2>/dev/null | head -n1
}

# Live id + workspace of the CALLING pane, as "pane_id<TAB>workspace_id", empty
# when unresolvable. HERDR_PANE_ID is the id at pane LAUNCH and goes stale the
# moment the pane is moved, so it must never be used as an argument (pane move
# rejects a dead id). --current is what resolves the caller to its live pane,
# even after a previous move rewrote the id.
_view_caller() {
  herdr pane current --current 2>/dev/null \
    | jq -r '[.result.pane.pane_id // empty,
              .result.pane.workspace_id // empty] | @tsv' 2>/dev/null | head -n1
}

# Workspace herdr treats as the repo's home (the non-linked checkout's workspace).
# This is where a pane that must outlive a worktree goes.
_view_home_workspace() {
  herdr worktree list --cwd "$(_view_repo_root)" --json 2>/dev/null \
    | jq -r '.result.source.source_workspace_id // empty' 2>/dev/null | head -n1
}

# Move the CALLER's pane into TARGET. The run happens in that pane, so a view
# nobody is inside is a lie: the session belongs where the work is. No-op when
# the caller is not in a herdr pane or is already there.
_view_attach_caller() {
  local target=$1
  [[ -n $target ]] || return 0
  local info cur pane
  info=$(_view_caller || true)
  [[ -n $info ]] || return 0
  cur=${info#*$'\t'} pane=${info%%$'\t'*}
  [[ -n $pane && -n $cur && $cur != "$target" ]] || return 0
  herdr pane move "$pane" --new-tab --workspace "$target" --no-focus \
    >/dev/null 2>&1
}

# Move the CALLER's pane OUT of FROM before FROM is torn down. Closing a
# workspace closes its panes, and the caller's pane is the session running the
# pipeline itself: it has to survive the worktree. Returns non-zero when the
# caller is inside FROM and a safe landing spot could not be used.
_view_detach_caller() {
  local from=$1
  [[ -n $from ]] || return 0
  local info cur pane
  info=$(_view_caller || true)
  [[ -n $info ]] || return 1
  cur=${info#*$'\t'} pane=${info%%$'\t'*}
  [[ -n $pane ]] || return 1
  [[ $cur == "$from" ]] || return 0
  local home
  home=$(_view_home_workspace || true)
  [[ -n $home && $home != "$from" ]] || return 1
  herdr pane move "$pane" --new-tab --workspace "$home" --no-focus \
    >/dev/null 2>&1
}

# Open an editor on the worktree as a right-hand pane, ONCE. Idempotent by
# inspection, not by state: if any pane in the workspace already runs the
# editor, the layout is the user's and is left alone. Runs after the attach, so
# --current is the caller's pane now sitting inside the worktree workspace.
# "name<TAB>cmdline" of PANE's foreground process, empty on error. Matching on
# the raw name alone is not enough: hunk runs as `node .../hunk`, so a tool has
# to be recognisable by its command line as well.
_pane_fg() { # <pane>
  herdr pane process-info --pane "$1" 2>/dev/null \
    | jq -r '[.result.process_info.foreground_processes[0].name // empty,
              .result.process_info.foreground_processes[0].cmdline // empty]
             | @tsv' 2>/dev/null
}

_view_pane_runs() { # _view_pane_runs <workspace> <prog>
  local ws=$1 want=$2 pane fg name cmd
  while read -r pane; do
    [[ -n $pane ]] || continue
    fg=$(_pane_fg "$pane") || continue
    name=${fg%%$'\t'*} cmd=${fg#*$'\t'}
    [[ $name == "$want" || $cmd == *"$want"* ]] && return 0
  done < <(herdr pane list --workspace "$ws" 2>/dev/null \
             | jq -r '.result.panes[]?.pane_id' 2>/dev/null)
  return 1
}

# Block until PANE has an interactive shell in the foreground. A freshly split
# pane has no shell yet, and `pane run` before that point loses the keystrokes,
# which is exactly how a tool pane ends up as a bare prompt.
_view_pane_wait_shell() { # <pane>
  local pane=$1 i name=''
  for ((i = 0; i < 24; i++)); do
    name=$(herdr pane process-info --pane "$pane" 2>/dev/null \
      | jq -r '.result.process_info.foreground_processes[0].name // empty' \
      2>/dev/null) || name=''
    case $name in fish|bash|zsh|sh|dash|ksh|nu|xonsh) return 0 ;; esac
    sleep 0.25
  done
  return 1
}

# Open a tool pane on the worktree, ONCE. Sets VIEW_NEW_PANE to the pane it
# opened, empty when the tool was already there or absent — never prints to
# stdout, which belongs to the JSON contract. Status: 0 ok (opened or already
# present), 1 could not open, 2 tool not installed. ANCHOR is the pane to split;
# the caller's own pane when empty.
VIEW_NEW_PANE=''
_view_open_tool() { # <workspace> <cwd> <prog> <command> <direction> [anchor]
  local ws=$1 cwd=$2 prog=$3 cmd=$4 dir=$5 anchor=${6:-}
  VIEW_NEW_PANE=''
  [[ -n ${HERDR_ENV:-} && -n $ws && -n $cwd ]] || return 0
  command -v "$prog" >/dev/null 2>&1 || return 2
  _view_pane_runs "$ws" "$prog" && return 0
  local -a split=(pane split --direction "$dir" --cwd "$cwd" --no-focus)
  if [[ -n $anchor ]]; then split+=(--pane "$anchor"); else split+=(--current); fi
  local out new fg name cmd i=0
  out=$(herdr "${split[@]}" 2>/dev/null) || return 1
  new=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null) || new=''
  [[ -n $new ]] || return 1
  _view_pane_wait_shell "$new" || true
  # Verify the tool actually took over the pane: a lost keystroke is silent.
  while (( i < 3 )); do
    herdr pane run "$new" "$cmd" >/dev/null 2>&1 || true
    sleep 0.4
    fg=$(_pane_fg "$new") || fg=''
    name=${fg%%$'\t'*} cmd=${fg#*$'\t'}
    if [[ $name == "$prog" || $cmd == *"$prog"* ]]; then
      VIEW_NEW_PANE=$new
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# --- ensure -----------------------------------------------------------------

# The planning directory must be STABLE for a given branch: on resume the
# orchestrator calls ensure again and has to get the same path the planner
# already wrote into, or the artifacts split across two directories. So an
# existing directory for this exact type+slug always wins over a fresh number,
# and {NNNN} is only allocated when there is none.
#
# Shared by ensure and resolve on purpose. If the two ever disagreed, resolve
# would hand a child a path that no other step of the run knows about — a
# failure that looks like success from inside the child.
planning_dir_for() { # <worktree> <type> <slug>
  local wt=$1 type=$2 slug=$3 d base_name
  for d in "$wt"/docs/planning/*-"$type-$slug"; do
    [[ -d $d ]] || continue
    base_name=$(basename "$d")
    # Guard against a longer slug whose tail matches, e.g. `x-add-dark-mode`.
    [[ $base_name == *-"$type-$slug" ]] || continue
    printf '%s\n' "$d"
    return 0
  done

  local max=0
  for d in "$wt"/docs/planning/[0-9]*; do
    [[ -d $d ]] || continue
    base_name=$(basename "$d"); base_name=${base_name%%-*}
    [[ $base_name =~ ^[0-9]+$ ]] || continue
    (( 10#$base_name > max )) && max=$((10#$base_name))
  done
  printf '%s\n' "$wt/docs/planning/$(printf '%04d' $((max + 1)))-$type-$slug"
}

cmd_ensure() {
  local type='' slug='' base=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --type)  type=${2:-};  shift 2 ;;
      --slug)  slug=${2:-};  shift 2 ;;
      --base)  base=${2:-};  shift 2 ;;
      -h|--help) usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  [[ -n $type ]] || fail "missing_--type"
  [[ -n $slug ]] || fail "missing_--slug"
  # Guardrail: the branch name is the one artifact a hallucinating model could
  # turn into `main`, `HEAD`, `../../etc` or a ref with spaces.
  [[ " $VALID_TYPES " == *" $type "* ]] || fail "invalid_type_$type"
  [[ $slug =~ $SLUG_RE ]] || fail "invalid_slug_$slug"
  local prefix
  prefix=$(branch_prefix_for "$type") || fail "invalid_type_$type"

  need git
  need wt

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not_a_git_work_tree"

  local branch="$prefix/$slug"
  local reused=false wt=''

  # Never nest: running from inside another linked worktree only reuses it when
  # it already holds the target branch. Anything else is the user's call.
  if is_linked_worktree; then
    local current
    current=$(git branch --show-current 2>/dev/null)
    if [[ $current != "$branch" ]]; then
      fail "already_in_linked_worktree" \
        "$(jq -nc --arg b "$current" --arg w "$(pwd -P)" '{current_branch: $b, current_worktree: $w}')"
    fi
    wt=$(pwd -P)
    reused=true
  fi

  if [[ -z $wt ]]; then
    wt=$(worktree_for_branch "$branch" || true)
    [[ -n $wt ]] && reused=true
  fi

  if [[ -z $wt ]]; then
    # One command covers both cases: worktrunk creates the worktree for an
    # existing ref and creates the branch when it does not exist yet. --no-cd
    # keeps it from changing directory (a subagent shell could not act on a cd);
    # --yes is what actually makes it headless: project hooks (pre-start,
    # post-start) otherwise prompt for approval and fail without a TTY.
    local out rc=0
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      out=$(wt --yes switch "$branch" --no-cd --format=json 2>/dev/null | head -n1) || rc=$?
    else
      local -a args=(--yes switch --create "$branch" --no-cd --format=json)
      [[ -n $base ]] && args+=(--base "$base")
      out=$(wt "${args[@]}" 2>/dev/null | head -n1) || rc=$?
    fi
    [[ $rc -eq 0 ]] || fail "worktree_create_failed"
    wt=$(printf '%s' "$out" | jq -r '.path // empty' 2>/dev/null) || wt=''
    [[ -n $wt ]] || fail "worktree_create_returned_no_path"
  fi

  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "worktree_path_invalid" "$(jq -nc --arg w "$wt" '{worktree: $w}')"

  # The view is presentation, never a dependency: a failure here degrades to a
  # warning and the run continues without it.
  local view_id='' view_open=false
  if view_backend; then
    view_open=true
    view_id=$(_view_on "$wt" || true)
    if [[ -z $view_id ]]; then
      # --cwd must be the repository root: worktree open rejects a linked
      # worktree's own workspace. --no-focus so the pipeline never steals focus.
      local out rc=0
      out=$(herdr worktree open --cwd "$(_view_repo_root)" --path "$wt" \
        --label "$branch" --no-focus --json 2>/dev/null | head -n1) || rc=$?
      if [[ $rc -eq 0 ]]; then
        view_id=$(printf '%s' "$out" \
          | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null) || view_id=''
        [[ -n $view_id ]] || warn+=("view_open_returned_no_id")
      else
        warn+=("view_open_failed_not_attached")
      fi
    fi
    # The view is only useful if the run is inside it, so pull the caller's pane
    # into the worktree workspace. Best-effort: a layout we could not change must
    # not fail the run, it just warns.
    [[ -n $view_id ]] && { _view_attach_caller "$view_id" || warn+=("view_attach_move_failed"); }
    # Editor on the right, diff viewer under it. Both opened once; status 2 means
    # the tool is not installed, which is not a failure, just skip it.
    if [[ -n $view_id ]]; then
      local ed='' st=0
      _view_open_tool "$view_id" "$wt" nvim "nvim ." right \
        || { st=$?; [[ $st -eq 2 ]] || warn+=("view_nvim_open_failed"); }
      ed=$VIEW_NEW_PANE
      _view_open_tool "$view_id" "$wt" hunk "hunk diff --watch" right "${ed:-}" \
        || { st=$?; [[ $st -eq 2 ]] || warn+=("view_hunk_open_failed"); }
    fi
  fi

  local planning_dir
  planning_dir=$(planning_dir_for "$wt" "$type" "$slug")

  # The session-directory contract: where the session is now, where it must end
  # up, and whether it is already there. On a fresh run this is match:false by
  # construction — the worktree did not exist a moment ago — and the orchestrator
  # has to relocate. On a resume it is match:true and there is nothing to do.
  local loc_here loc_harness loc_match=false
  loc_here=$(pwd -P)
  loc_harness=$(harness_id)
  [[ $loc_here == "$wt" ]] && loc_match=true

  jq -nc \
    --arg branch "$branch" \
    --arg worktree "$wt" \
    --arg view_id "$view_id" \
    --arg planning_dir "$planning_dir" \
    --argjson view_open "$view_open" \
    --argjson reused "$reused" \
    --argjson warnings "$(warnings_json)" \
    --arg loc_here "$loc_here" \
    --arg loc_harness "$loc_harness" \
    --argjson loc_match "$loc_match" \
    '{ok: true, branch: $branch, worktree: $worktree, view_id: $view_id,
      planning_dir: $planning_dir, view_open: $view_open, reused: $reused,
      session_location: {required: $worktree, current: $loc_here,
                         match: $loc_match, harness: $loc_harness},
      warnings: $warnings}'
  exit 0
}

# --- session location -------------------------------------------------------

# Which harness owns this shell, best-effort from the process ancestry. Every
# harness runs its shell tool as a descendant of the harness process, so the
# answer is reachable without any cooperation from the harness itself and
# without an environment variable that no known harness sets. `unknown` is an
# honest answer: it means "assume no relocation capability", not "no harness".
harness_id() {
  local p=$$ ppid comm i
  for ((i = 0; i < 8; i++)); do
    read -r ppid comm < <(ps -o ppid=,comm= -p "$p" 2>/dev/null) || break
    [[ -n $comm ]] || break
    case $comm in
      opencode)    printf 'opencode\n'; return 0 ;;
      codex)       printf 'codex\n';    return 0 ;;
      pi|pi-mono)  printf 'pi\n';       return 0 ;;
    esac
    [[ $ppid =~ ^[0-9]+$ ]] || break
    p=$ppid
    ((p <= 1)) && break
  done
  printf 'unknown\n'
}

# Where the session lives right now, and whether it is where the caller expects.
#
# No harness API is involved and none is needed: every harness runs its shell
# with cwd = the session directory, so `pwd -P` IS the session location. That is
# what makes this check portable across opencode, codex and pi.
#
# A mismatch is not a failure — it is the expected state right after `ensure`,
# before the orchestrator has relocated. So the exit stays 0 and `match` carries
# the answer; a caller that wants the run to stop must act on `match:false`.
cmd_location() {
  local expect=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --expect) expect=${2:-}; shift 2 ;;
      -h|--help) usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  local here harness
  here=$(pwd -P)
  harness=$(harness_id)

  if [[ -z $expect ]]; then
    jq -nc --arg session_dir "$here" --arg harness "$harness" \
      '{ok: true, session_dir: $session_dir, harness: $harness}'
    exit 0
  fi

  # Normalize so symlinked paths and trailing slashes do not read as a mismatch.
  local want
  want=$(cd "$expect" 2>/dev/null && pwd -P) \
    || fail "expect_not_a_directory" "$(jq -nc --arg d "$expect" '{expected: $d}')"

  local match=false
  [[ $here == "$want" ]] && match=true

  jq -nc --arg session_dir "$here" --arg expected "$want" \
         --arg harness "$harness" --argjson match "$match" \
    '{ok: true, match: $match, session_dir: $session_dir,
      expected: $expected, harness: $harness}'
  exit 0
}

# --- resolve ----------------------------------------------------------------

# The run's paths, obtainable ONLY from inside the run's worktree.
#
# This is the deterministic half of the location contract. A child session is
# born wherever its parent lives, so a child launched before the orchestrator
# relocated would otherwise work in the primary checkout — silently, on the
# wrong branch. `resolve` takes that possibility away from the wrong side of the
# fence: the child does not RECEIVE worktree/planning_dir, it FETCHES them, and
# from the wrong directory there is nothing to fetch. A child that skips this
# step has no paths and cannot act at all, which is a failure that cannot be
# mistaken for success — unlike a child that merely forgets to check.
#
# It needs no harness API, so the same gate protects opencode, codex and pi.
#
# --from-anywhere is the one named exception: the closer, which runs AFTER the
# orchestrator left the worktree (it is the agent that destroys it) and therefore
# cannot be inside. Every other agent is inside by construction.
cmd_resolve() {
  local branch='' from_anywhere=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --branch)        branch=${2:-}; shift 2 ;;
      --from-anywhere) from_anywhere=true; shift ;;
      -h|--help)       usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done
  [[ -n $branch ]] || fail "missing_--branch"
  need git

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not_a_git_work_tree"

  # The branch carries the whole run identity: `<prefix>/<slug>`. Anything that
  # does not decompose that way was not created by ensure, so refuse rather than
  # guess which run it is supposed to be.
  local prefix=${branch%%/*} slug=${branch#*/} type=''
  [[ $prefix != "$branch" && -n $slug ]] || fail "invalid_branch_$branch"
  type=$(type_from_prefix "$prefix") || fail "invalid_branch_$branch"

  local wt
  wt=$(worktree_for_branch "$branch" || true)
  [[ -n $wt ]] || fail "no_worktree_for_branch" \
    "$(jq -nc --arg b "$branch" '{branch: $b}')"

  # Normalize before comparing: a symlinked checkout must not read as a
  # mismatch, because a gate that misfires is worse than no gate — it would
  # block a correctly-placed child.
  local wt_real
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt

  local here
  here=$(pwd -P)
  if [[ $from_anywhere != true && $here != "$wt_real" ]]; then
    fail "wrong_location" \
      "$(jq -nc --arg w "$wt_real" --arg s "$here" \
          '{expected: $w, session_dir: $s, move_to: $w,
            hint: "this run is worked from inside its worktree; relocate the session there and call resolve again"}')"
  fi

  local planning_dir
  planning_dir=$(planning_dir_for "$wt_real" "$type" "$slug")

  jq -nc --arg branch "$branch" --arg worktree "$wt_real" \
         --arg planning_dir "$planning_dir" --arg harness "$(harness_id)" \
         --argjson from_anywhere "$from_anywhere" \
    '{ok: true, branch: $branch, worktree: $worktree,
      planning_dir: $planning_dir, harness: $harness,
      from_anywhere: $from_anywhere}'
  exit 0
}

# --- remove -----------------------------------------------------------------

# NOTE: `wt remove` is unsafe outside a TTY. It never prompts and never refuses,
# so the guards below are the only thing standing between a stray call and
# destroyed work. Verified: a branch with an unmerged commit was removed
# non-interactively with no warning. --foreground is what makes worktrunk ask,
# and that needs a real terminal, which a subagent does not have.
cmd_remove() {
  local branch='' worktree='' base='' force=false force_delete=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --branch)       branch=${2:-}; shift 2 ;;
      --worktree)     worktree=${2:-}; shift 2 ;;
      --base)         base=${2:-}; shift 2 ;;
      --force)        force=true; shift ;;
      --force-delete) force_delete=true; shift ;;
      -h|--help)      usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  [[ -n $branch ]] || fail "missing_--branch"
  need git
  need wt

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not_a_git_work_tree"

  # The branch must look like a real ref; anything else could target a remote
  # ref or be interpreted by worktrunk as a shortcut (pr:N, mr:N, ^, -).
  [[ $branch =~ ^[a-z]+/[a-z0-9]+(-[a-z0-9]+)*$ ]] \
    || fail "invalid_branch_$branch"
  # And it must exist as a local branch. Without this, `origin/main` passes the
  # shape check, matches no worktree, and comes back as a silent ok:true that a
  # caller would read as "cleanup done".
  git show-ref --verify --quiet "refs/heads/$branch" \
    || fail "branch_not_found" "$(jq -nc --arg b "$branch" '{branch: $b}')"

  [[ -n $worktree ]] || worktree=$(worktree_for_branch "$branch" || true)
  if [[ -z $worktree ]]; then
    # Goal state is "no worktree for this branch", so nothing to do is success.
    # Detached worktrees are the exception worth reporting: they are invisible to
    # worktree_for_branch (it matches on `branch refs/heads/...`) and can hold the
    # only copy of a commit, so a bare ok:true hides real work left on disk.
    local det
    while IFS= read -r det; do
      [[ -n $det ]] || continue
      warn+=("detached_worktree_left_in_place_$(basename "$det")")
    done < <(detached_worktrees || true)
    jq -nc --arg branch "$branch" --argjson warnings "$(warnings_json)" \
      '{ok: true, removed: false, branch: $branch, reason: "worktree_not_found",
        view_id: "", warnings: $warnings}'
    exit 0
  fi
  git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "worktree_path_invalid" "$(jq -nc --arg w "$worktree" '{worktree: $w}')"

  # The path about to be deleted has to be the one holding the branch. A path on
  # another branch, or detached, is not this command's to remove: `wt remove
  # <branch>` would act on a DIFFERENT worktree and leave this one standing,
  # while the git fallback would delete a directory no branch points at. Refuse
  # before touching anything instead of half-doing it.
  local head_ref
  head_ref=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null) || head_ref=''
  [[ $head_ref == "$branch" ]] \
    || fail "worktree_not_on_branch" \
         "$(jq -nc --arg w "$worktree" --arg b "$branch" --arg h "$head_ref" \
              '{worktree: $w, branch: $b,
                head: (if $h == "" then "detached" else $h end),
                hint: "refusing to remove a worktree not checked out at this branch"}')"

  local primary
  primary=$(primary_checkout)
  local wt_real
  wt_real=$(cd "$worktree" && pwd -P)
  if [[ $wt_real == "$primary" ]]; then
    fail "refusing_primary_checkout" "$(jq -nc --arg p "$worktree" '{worktree: $p}')"
  fi

  # The caller's own session must not sit inside the worktree about to be
  # destroyed. Removing it leaves that session with a dead cwd — shell, globs and
  # file reads break at once — and that is the whole reason the location
  # lifecycle is two-phase: in the worktree for the run, out before close.
  #
  # Relocating a live session is a harness capability this script does not have
  # (see the header), so the only honest move is to refuse and say where the
  # session must go first. Deliberately not bypassable with --force: forcing here
  # would not override a safety net, it would break the caller's own shell.
  local session_dir
  session_dir=$(pwd -P)
  case $session_dir in
    "$wt_real"|"$wt_real"/*)
      fail "session_inside_worktree" \
        "$(jq -nc --arg w "$wt_real" --arg s "$session_dir" --arg p "$primary" \
            '{worktree: $w, session_dir: $s, move_to: $p,
              hint: "relocate the session out of the worktree first, verify with location --expect, then call remove again"}')" ;;
  esac

  local -a args=(--yes remove --no-delete-branch "$branch")
  local use_git_fallback=false

  # Guard 1: uncommitted or untracked work. -f is worktrunk's override.
  if [[ -n $(git -C "$worktree" status --porcelain 2>/dev/null) ]]; then
    if [[ $force == true ]]; then
      args+=(-f)
      warn+=("forced_past_dirty_worktree")
    else
      fail "dirty_worktree" \
        "$(jq -nc --arg w "$worktree" '{worktree: $w, hint: "pass --force to override"}')"
    fi
  fi

  # Guard 2: commits the target has and the base does not. Note this is a net
  # against accidents, not a merge check: after a rebase-merge the local branch
  # is not an ancestor of base even though the work landed, which is why the
  # closer passes --force-delete backed by the forge's MERGED state.
  [[ -n $base ]] || base=$(git -C "$primary" branch --show-current 2>/dev/null)
  if [[ -n $base ]] && git -C "$worktree" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    local ahead
    ahead=$(git -C "$worktree" rev-list --count "$base..$branch" 2>/dev/null) || ahead=0
    if [[ ${ahead:-0} -gt 0 ]]; then
      if [[ $force_delete == true ]]; then
        # worktrunk refuses -D together with --no-delete-branch, and the branch
        # must survive for the closer's own `git branch -D`. So the worktree
        # goes through git directly, which skips any worktrunk remove hook.
        use_git_fallback=true
        warn+=("forced_past_unmerged_commits_ahead_$ahead")
        warn+=("removed_with_git_worktrunk_remove_hooks_skipped")
      else
        fail "unmerged_commits" \
          "$(jq -nc --arg w "$worktree" --arg b "$branch" --arg base "$base" \
               --argjson ahead "$ahead" \
               '{worktree: $w, branch: $b, base: $base, ahead: $ahead,
                 hint: "pass --force-delete only when the merge is proven"}')"
      fi
    fi
  fi

  # Resolved BEFORE removal: the view backend forgets the mapping once the
  # worktree is gone.
  local view_id=''
  if view_backend; then
    view_id=$(_view_on "$worktree" || true)
    [[ -n $view_id ]] || warn+=("view_not_open")
  fi

  # The caller's pane may be sitting inside the worktree workspace. Pull it out
  # before the checkout disappears under its feet, or the very command that
  # removed it leaves the session running from a dead cwd. Best-effort: warn.
  [[ -n $view_id ]] && { _view_detach_caller "$view_id" || warn+=("view_detach_move_failed"); }

  if [[ $use_git_fallback == true ]]; then
    git worktree remove --force "$worktree" \
      || fail "worktree_remove_failed" \
           "$(jq -nc --arg w "$worktree" '{worktree: $w}')"
  else
    wt "${args[@]}" >/dev/null 2>&1 \
      || fail "worktree_remove_rejected" "$(jq -nc --arg b "$branch" '{branch: $b}')"
  fi

  # The toolchain reported success, so the directory has to be gone. If it is not,
  # `removed:true` would be a lie the caller acts on (it stops asking, stops
  # cleaning, and never learns the worktree is still there), and a warning in a
  # field nobody reads is not a safety net. Fail loudly instead.
  if [[ -e $worktree ]]; then
    fail "worktree_remove_incomplete" \
      "$(jq -nc --arg w "$worktree" \
           '{worktree: $w, hint: "removal reported success but the path survives"}')"
  fi

  jq -nc --arg branch "$branch" --arg worktree "$worktree" \
    --arg view_id "$view_id" \
    --argjson warnings "$(warnings_json)" \
    '{ok: true, removed: true, branch: $branch, worktree: $worktree,
      view_id: $view_id, warnings: $warnings}'
  exit 0
}

# --- close ------------------------------------------------------------------

# Detaches the visual surface. Idempotent by design: the goal state is "no view
# on this worktree", so an id that is already gone, or an empty id, is success.
# Never fails the run — the orchestrator reports a problem here in `risks` only.
cmd_close() {
  local view_id=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --view) view_id=${2:-}; shift 2 ;;
      -h|--help) usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  if [[ -z $view_id ]]; then
    jq -nc '{ok: true, closed: false, reason: "no_view", warnings: []}'
    exit 0
  fi

  if ! view_backend; then
    # Nothing can be detached without the backend, and by now the run is over,
    # so this is a leftover surface, not a broken pipeline.
    jq -nc --argjson warnings "$(warnings_json)" \
      '{ok: true, closed: false, reason: "view_backend_unavailable", warnings: $warnings}'
    exit 0
  fi

  # Idempotence first: if the workspace is already gone, there is nothing to
  # detach or close, and no caller could be standing in it.
  if ! herdr workspace get "$view_id" >/dev/null 2>&1; then
    jq -nc '{ok: true, closed: false, reason: "already_closed", warnings: []}'
    exit 0
  fi

  # Never close a workspace the session is standing in: closing it takes the
  # orchestrator's own pane down with it. If we cannot PROVE the caller is
  # elsewhere, refuse — a leaked workspace is survivable, a killed session is not.
  if ! _view_detach_caller "$view_id"; then
    fail "view_close_unsafe_caller" \
      "$(jq -nc --arg v "$view_id" \
           '{view_id: $v, hint: "the caller pane could not be moved out of the view workspace"}')"
  fi

  # This command group answers in JSON but sends its ERRORS on stderr, so both
  # streams are captured; and a real error exits non-zero, so the exit status is
  # deliberately ignored in favour of the payload.
  local out
  out=$(herdr workspace close "$view_id" 2>&1 | head -n1) || true

  if printf '%s' "$out" | jq -e '.error.code == "workspace_not_found"' >/dev/null 2>&1; then
    jq -nc --argjson warnings "$(warnings_json)" \
      '{ok: true, closed: false, reason: "already_closed", warnings: $warnings}'
    exit 0
  fi
  if printf '%s' "$out" | jq -e '.error' >/dev/null 2>&1; then
    local code msg
    code=$(printf '%s' "$out" | jq -r '.error.code // "unknown"')
    msg=$(printf '%s' "$out" | jq -r '.error.message // ""')
    fail "view_close_failed" \
      "$(jq -nc --arg c "$code" --arg m "$msg" '{code: $c, message: $m}')"
  fi
  if [[ -z $out ]]; then
    fail "view_close_no_response"
  fi

  jq -nc --argjson warnings "$(warnings_json)" \
    '{ok: true, closed: true, reason: "closed", warnings: $warnings}'
  exit 0
}

# --- dispatch ---------------------------------------------------------------

main() {
  local cmd=${1:-}
  case $cmd in
    ensure) shift; cmd_ensure "$@" ;;
    location) shift; cmd_location "$@" ;;
    resolve) shift; cmd_resolve "$@" ;;
    remove) shift; cmd_remove "$@" ;;
    close)  shift; cmd_close "$@" ;;
    ''|-h|--help|help) usage ;;
    *) fail "unknown_subcommand_$cmd" ;;
  esac
}

main "$@"
