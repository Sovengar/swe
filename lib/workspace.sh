#!/usr/bin/env bash
# workspace.sh — the lifecycle verbs that materialize and tear down a run's
# working environment and its planning directory: `ensure` and `remove`.

swe_source_once core.sh git.sh identity.sh view.sh

# --- ensure -----------------------------------------------------------------

# A candidate this run may DECLARE as its base: an existing branch, spelled the
# way the refs hold it. Anything else — a detached HEAD's empty current name, a
# pinned commit, a stale typo — prints nothing, so the caller leaves no
# declaration and the verbs keep their own resolution instead of inheriting a
# guess that would refuse later.
_run_base_name() { # <candidate>
  local name=$1
  [[ -n $name ]] || return 1
  git rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1 \
    || git rev-parse --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1 \
    || return 1
  printf '%s' "$name"
}

# A probe answers with a ref that may carry a remote prefix: `origin/main` from
# git and `gb-local/main` from but's local pseudo-remote. A run's base is the
# branch, never the remote it happens to be fetched through.
_run_base_strip_remote() { # <ref>
  local ref=$1
  case $ref in
    */*) printf '%s' "${ref#*/}" ;;
    *)   printf '%s' "$ref" ;;
  esac
}

# A name this run may report as its base. `gitbutler/workspace` is GitButler's
# synthetic merge branch, not a base: recording it cuts every worktree from the
# workspace instead of from the branch the run integrates into. `HEAD` and the
# empty string are what a detached checkout answers, and are equally unusable.
_run_base_usable() { # <name>
  local name=$1
  [[ -n $name && $name != HEAD && $name != gitbutler/workspace ]]
}

# The GitButler target when but can answer for this repository. `but config
# target` prints a human block, not a bare ref, so take the first line that
# looks like a branch (a URL, a label with spaces or a colon is not one) and
# strip the remote it is spelled with. Any failure — but missing, not a
# workspace, config unreadable — prints nothing and is the caller's cue to fall
# through; no probe here may fail the run.
_but_target_branch() {
  command -v but >/dev/null 2>&1 || return 1
  local out='' line=''
  out=$(but config target 2>/dev/null) || return 1
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n $line ]] || continue
    [[ $line =~ ^[A-Za-z0-9._/-]+$ ]] || continue
    _run_base_strip_remote "$line"
    return 0
  done <<< "$out"
  return 1
}

# Resolve the run's integration base, first hit wins:
#   1. the GitButler target (but config target), remote prefix stripped;
#   2. origin/HEAD, the remote's default branch as this clone recorded it;
#   3. the current branch, for repositories with no remote at all.
# A candidate that is unusable (synthetic `gitbutler/workspace`, `HEAD`, empty)
# falls through to the next rule. Prints nothing when none yields a real branch.
_run_base_resolve() {
  local candidate=''

  candidate=$(_but_target_branch) || candidate=''
  _run_base_usable "$candidate" && { printf '%s\n' "$candidate"; return 0; }

  candidate=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null) || candidate=''
  candidate=${candidate#origin/}
  _run_base_usable "$candidate" && { printf '%s\n' "$candidate"; return 0; }

  candidate=$(git branch --show-current 2>/dev/null) || candidate=''
  _run_base_usable "$candidate" && { printf '%s\n' "$candidate"; return 0; }

  return 1
}

cmd_ensure() {
  local type='' slug='' base='' environment=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --type)        type=${2:-};        shift 2 ;;
      --slug)        slug=${2:-};        shift 2 ;;
      --base)        base=${2:-};        shift 2 ;;
      --environment) environment=${2:-}; shift 2 ;;
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
  # `parallel-branch` was an environment once and is now a vcs capability
  # (stacked/parallel branches live inside `shared` or `worktree`). Refuse the
  # removed token explicitly, before the generic validation, so the caller gets
  # the migration reason instead of `invalid_environment_parallel-branch`.
  [[ $environment != parallel-branch ]] \
    || fail "parallel_branch_is_a_vcs_capability" \
      '{"hint":"parallel-branch is not an isolation environment: isolation says WHERE (shared|worktree) and vcs says HOW (gitbutler|jj). Pick `shared` or `worktree` and choose the driver with /vcs."}'
  [[ -z $environment || " $VALID_ENVIRONMENTS " == *" $environment "* ]] \
    || fail "invalid_environment_$environment"
  local prefix
  prefix=$(branch_prefix_for "$type") || fail "invalid_type_$type"

  # Which environment this run wants: `worktree` | `shared` (ADR-0005). Left
  # unset it is DERIVED from availability, which is the historical behavior: a
  # repository gets a worktree, no repository gets shared. `worktree` REQUIRES a
  # repository, so asking for one without a repository is not a failure — it
  # downgrades to `shared` WITH the reason, and the run continues. A run is never
  # blocked by the absence of git.
  local no_repo=false
  in_git_repository || no_repo=true
  if [[ $no_repo == true ]]; then
    [[ $environment == shared || -z $environment ]] \
      || warn+=("environment_downgraded_to_shared_no_repository_$environment")
    environment=shared
  elif [[ -z $environment ]]; then
    environment=worktree
  fi

  # `shared` is an environment, not the absence of one: the run happens where
  # the session already is — no branch, no working environment — and it still
  # owns an artifacts root. The planning directory is allocated INSIDE the
  # working environment, and for `shared` the working environment is this
  # directory. That is what lets a structured flow run with no repository at all.
  if [[ $environment == shared ]]; then
    local in_place_here in_place_harness in_place_planning
    in_place_here=$(pwd -P)
    in_place_harness=$(harness_id)
    in_place_planning=$(planning_dir_for "$in_place_here" "$type" "$slug")
    jq -nc --arg we "$in_place_here" --arg harness "$in_place_harness" \
      --arg environment "$environment" --arg planning_dir "$in_place_planning" \
      --argjson warnings "$(warnings_json)" \
      '{ok: true, git: false, in_place: true, environment: $environment,
        branch: "", workingEnvironment: $we,
        view_id: "", planning_dir: $planning_dir, view_open: false, reused: false,
        base_branch: "",
        session_location: {required: $we, current: $we, match: true, harness: $harness},
        warnings: $warnings}'
    exit 0
  fi

  need git
  need wt

  # The base this run integrates into is resolved ONCE, here, and captured
  # BEFORE the working environment exists: creating it may move this checkout
  # onto the run's own branch, and after that `--show-current` in here names
  # the change, not its base. The probe order and the synthetic-branch rejection
  # live in `_run_base_resolve`; when every rule fails the run continues with no
  # base and says so, instead of recording a branch that is not a base.
  local resolved_base=''
  if ! resolved_base=$(_run_base_resolve); then
    resolved_base=''
    warn+=("base_branch_unresolved")
  fi

  local branch="$prefix/$slug"
  local reused=false we=''

  # Never nest: running from inside another working environment only reuses it
  # when it already holds the target branch. Anything else is the user's call.
  if is_linked_checkout; then
    local current
    current=$(git branch --show-current 2>/dev/null)
    if [[ $current != "$branch" ]]; then
      fail "already_in_working_environment" \
        "$(jq -nc --arg b "$current" --arg w "$(pwd -P)" '{current_branch: $b, current_workingEnvironment: $w}')"
    fi
    we=$(pwd -P)
    reused=true
  fi

  if [[ -z $we ]]; then
    we=$(working_environment_for_branch "$branch" || true)
    [[ -n $we ]] && reused=true
  fi

  if [[ -z $we ]]; then
    # One command covers both cases: the backend creates the working environment
    # for an existing ref and creates the branch when it does not exist yet.
    # --no-cd keeps it from changing directory (a subagent shell could not act on
    # a cd); --yes is what actually makes it headless: project hooks (pre-start,
    # post-start) otherwise prompt for approval and fail without a TTY.
    #
    # The new branch is cut from the RESOLVED base, never from the caller's
    # current HEAD: in a GitButler workspace HEAD is `gitbutler/workspace`, the
    # synthetic merge branch, and branching from it would fold the workspace
    # into every run. Caller-pinned `--base` still wins.
    #
    # GitButler limit: `but commit` is not supported inside a linked worktree.
    # A run working in this worktree commits with git THERE — and `but setup`
    # must never run in a linked worktree; the but workspace belongs to the
    # primary checkout.
    local creation_base=$base
    [[ -n $creation_base ]] || creation_base=$resolved_base
    local out rc=0
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      out=$(wt --yes switch "$branch" --no-cd --format=json 2>/dev/null | head -n1) || rc=$?
    else
      local -a args=(--yes switch --create "$branch" --no-cd --format=json)
      [[ -n $creation_base ]] && args+=(--base "$creation_base")
      out=$(wt "${args[@]}" 2>/dev/null | head -n1) || rc=$?
    fi
    [[ $rc -eq 0 ]] || fail "working_environment_create_failed"
    we=$(printf '%s' "$out" | jq -r '.path // empty' 2>/dev/null) || we=''
    [[ -n $we ]] || fail "working_environment_create_returned_no_path"
  fi

  git -C "$we" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "working_environment_path_invalid" "$(jq -nc --arg w "$we" '{workingEnvironment: $w}')"

  # Declare the run's integration base, once: `--base` when the caller pinned a
  # name, otherwise the base resolved above. The declaration is
  # a file in the working environment's own git dir, because the verbs that
  # read it run in later sessions that never shared this shell's environment.
  # An existing declaration is never rewritten (the base is decided with
  # type/slug and never re-derived), and an unresolvable candidate leaves NO
  # declaration: the verbs then resolve the base themselves, as before.
  local base_branch='' gitdir='' runfile=''
  gitdir=$(git -C "$we" rev-parse --absolute-git-dir 2>/dev/null) || gitdir=''
  [[ -n $gitdir ]] && runfile="$gitdir/swe-run-base"
  if [[ -n $runfile && -f $runfile ]]; then
    base_branch=$(head -n1 "$runfile" 2>/dev/null) || base_branch=''
  else
    local declared=''
    declared=$(_run_base_name "$base") || declared=''
    if [[ -z $declared ]]; then
      declared=$(_run_base_name "$resolved_base") || declared=''
      # A run already sitting on its own branch declares nothing: the change is
      # not its own base.
      [[ $declared == "$branch" ]] && declared=''
    fi
    if [[ -n $runfile && -n $declared ]]; then
      if printf '%s\n' "$declared" >"$runfile" 2>/dev/null; then base_branch=$declared; fi
    fi
  fi

  # The view is presentation, never a dependency: a failure here degrades to a
  # warning and the run continues without it.
  local view_id='' view_open=false
  if view_backend; then
    view_open=true
    view_id=$(_view_on "$we" || true)
    if [[ -z $view_id ]]; then
      local open_rc=0
      view_id=$(_view_open "$we" "$branch") || open_rc=$?
      if [[ $open_rc -ne 0 ]]; then
        view_id=''
        warn+=("view_open_failed_not_attached")
      elif [[ -z $view_id ]]; then
        warn+=("view_open_returned_no_id")
      fi
    fi
    # The view is only useful if the run is inside it, so pull the caller's pane
    # into the workspace. Best-effort: a layout we could not change must
    # not fail the run, it just warns.
    [[ -n $view_id ]] && { _view_attach_caller "$view_id" || warn+=("view_attach_move_failed"); }
    # Now that the caller is inside, the workspace's own terminal is redundant.
    # Best-effort and silent: presentation never fails the run, and the reap
    # refuses to empty a workspace, so the view degrades to "shell kept" rather
    # than to "workspace gone".
    if [[ -n $view_id ]]; then
      _view_reap_placeholder "$view_id" "$we" || true
    fi
    # Editor on the right, diff viewer under it. Both opened once; status 2 means
    # the tool is not installed, which is not a failure, just skip it.
    if [[ -n $view_id ]]; then
      local ed='' st=0
      _view_open_tool "$view_id" "$we" nvim "nvim ." right \
        || { st=$?; [[ $st -eq 2 ]] || warn+=("view_nvim_open_failed"); }
      ed=$VIEW_NEW_PANE
      _view_open_tool "$view_id" "$we" hunk "hunk diff --watch" right "${ed:-}" \
        || { st=$?; [[ $st -eq 2 ]] || warn+=("view_hunk_open_failed"); }
    fi
  fi

  local planning_dir
  planning_dir=$(planning_dir_for "$we" "$type" "$slug")

  # The session-directory contract: where the session is now, where it must end
  # up, and whether it is already there. On a fresh run this is match:false by
  # construction — the working environment did not exist a moment ago — and the
  # orchestrator has to relocate. On a resume it is match:true and nothing to do.
  local loc_here loc_harness loc_match=false
  loc_here=$(pwd -P)
  loc_harness=$(harness_id)
  [[ $loc_here == "$we" ]] && loc_match=true

  jq -nc \
    --arg branch "$branch" \
    --arg environment "$environment" \
    --arg workingEnvironment "$we" \
    --arg view_id "$view_id" \
    --arg planning_dir "$planning_dir" \
    --arg base_branch "$base_branch" \
    --argjson view_open "$view_open" \
    --argjson reused "$reused" \
    --argjson warnings "$(warnings_json)" \
    --arg loc_here "$loc_here" \
    --arg loc_harness "$loc_harness" \
    --argjson loc_match "$loc_match" \
    '{ok: true, git: true, in_place: false, environment: $environment,
      branch: $branch, workingEnvironment: $workingEnvironment,
      view_id: $view_id,
      planning_dir: $planning_dir, view_open: $view_open, reused: $reused,
      base_branch: $base_branch,
      session_location: {required: $workingEnvironment, current: $loc_here,
                         match: $loc_match, harness: $loc_harness},
      warnings: $warnings}'
  exit 0
}

# --- remove -----------------------------------------------------------------

# NOTE: `wt remove` is unsafe outside a TTY. It never prompts and never refuses,
# so the guards below are the only thing standing between a stray call and
# destroyed work. Verified: a branch with an unmerged commit was removed
# non-interactively with no warning. --foreground is what makes worktrunk ask,
# and that needs a real terminal, which a subagent does not have.
cmd_remove() {
  local branch='' working_env='' base='' force=false force_delete=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --branch)       branch=${2:-}; shift 2 ;;
      --working-environment) working_env=${2:-}; shift 2 ;;
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

  in_git_repository || fail "not_a_git_repository"

  # The branch must look like a real ref; anything else could target a remote
  # ref or be interpreted by worktrunk as a shortcut (pr:N, mr:N, ^, -).
  [[ $branch =~ ^[a-z]+/[a-z0-9]+(-[a-z0-9]+)*$ ]] \
    || fail "invalid_branch_$branch"
  # And it must exist as a local branch. Without this, `origin/main` passes the
  # shape check, matches no working environment, and comes back as a silent ok:true that a
  # caller would read as "cleanup done".
  git show-ref --verify --quiet "refs/heads/$branch" \
    || fail "branch_not_found" "$(jq -nc --arg b "$branch" '{branch: $b}')"

  [[ -n $working_env ]] || working_env=$(working_environment_for_branch "$branch" || true)
  if [[ -z $working_env ]]; then
    # Goal state is "no working environment for this branch", so nothing to do is
    # success. Detached checkouts are the exception worth reporting: they are
    # invisible to a branch lookup and can hold the only copy of a commit, so a
    # bare ok:true hides real work left on disk.
    local det
    while IFS= read -r det; do
      [[ -n $det ]] || continue
      warn+=("detached_working_environment_left_in_place_$(basename "$det")")
    done < <(detached_working_environments || true)
    jq -nc --arg branch "$branch" --argjson warnings "$(warnings_json)" \
      '{ok: true, removed: false, branch: $branch,
        reason: "working_environment_not_found",
        view_id: "", warnings: $warnings}'
    exit 0
  fi
  git -C "$working_env" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "working_environment_path_invalid" \
         "$(jq -nc --arg w "$working_env" '{workingEnvironment: $w}')"

  # The path about to be deleted has to be the one holding the branch. A path on
  # another branch, or detached, is not this command's to remove: `wt remove
  # <branch>` would act on a DIFFERENT working environment and leave this one
  # standing, while the git fallback would delete a directory no branch points
  # at. Refuse before touching anything instead of half-doing it.
  local head_ref
  head_ref=$(git -C "$working_env" symbolic-ref --quiet --short HEAD 2>/dev/null) || head_ref=''
  [[ $head_ref == "$branch" ]] \
    || fail "working_environment_not_on_branch" \
         "$(jq -nc --arg w "$working_env" --arg b "$branch" --arg h "$head_ref" \
              '{workingEnvironment: $w, branch: $b,
                head: (if $h == "" then "detached" else $h end),
                hint: "refusing to remove a working environment not checked out at this branch"}')"

  local primary
  primary=$(primary_checkout)
  local we_real
  we_real=$(cd "$working_env" && pwd -P)
  if [[ $we_real == "$primary" ]]; then
    fail "refusing_primary_checkout" \
      "$(jq -nc --arg p "$working_env" '{workingEnvironment: $p}')"
  fi

  # The caller's own session must not sit inside the working environment about to
  # be destroyed. Removing it leaves that session with a dead cwd — shell, globs
  # and file reads break at once — and that is the whole reason the location
  # lifecycle is two-phase: in the working environment for the run, out before
  # close.
  #
  # Relocating a live session is a harness capability this script does not have
  # (see the header), so the only honest move is to refuse and say where the
  # session must go first. Deliberately not bypassable with --force: forcing here
  # would not override a safety net, it would break the caller's own shell.
  local session_dir
  session_dir=$(pwd -P)
  case $session_dir in
    "$we_real"|"$we_real"/*)
      fail "session_inside_working_environment" \
        "$(jq -nc --arg w "$we_real" --arg s "$session_dir" --arg p "$primary" \
            '{workingEnvironment: $w, session_dir: $s, move_to: $p,
              hint: "relocate the session out of the working environment first, verify with location --expect, then call remove again"}')" ;;
  esac

  local -a args=(--yes remove --no-delete-branch "$branch")
  local use_git_fallback=false

  # Guard 1: uncommitted or untracked work. -f is worktrunk's override.
  if [[ -n $(git -C "$working_env" status --porcelain 2>/dev/null) ]]; then
    if [[ $force == true ]]; then
      args+=(-f)
      warn+=("forced_past_dirty_working_environment")
    else
      fail "dirty_working_environment" \
        "$(jq -nc --arg w "$working_env" \
             '{workingEnvironment: $w, hint: "pass --force to override"}')"
    fi
  fi

  # Guard 2: commits the target has and the base does not. Note this is a net
  # against accidents, not a merge check: after a rebase-merge the local branch
  # is not an ancestor of base even though the work landed, which is why the
  # closer passes --force-delete backed by the forge's MERGED state.
  [[ -n $base ]] || base=$(git -C "$primary" branch --show-current 2>/dev/null)
  if [[ -n $base ]] && git -C "$working_env" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    local ahead
    ahead=$(git -C "$working_env" rev-list --count "$base..$branch" 2>/dev/null) || ahead=0
    if [[ ${ahead:-0} -gt 0 ]]; then
      if [[ $force_delete == true ]]; then
        # worktrunk refuses -D together with --no-delete-branch, and the branch
        # must survive for the closer's own `git branch -D`. So the working
        # environment goes through git directly, which skips any worktrunk hook.
        use_git_fallback=true
        warn+=("forced_past_unmerged_commits_ahead_$ahead")
        warn+=("removed_with_git_worktrunk_remove_hooks_skipped")
      else
        fail "unmerged_commits" \
          "$(jq -nc --arg w "$working_env" --arg b "$branch" --arg base "$base" \
               --argjson ahead "$ahead" \
               '{workingEnvironment: $w, branch: $b, base: $base, ahead: $ahead,
                 hint: "pass --force-delete only when the merge is proven"}')"
      fi
    fi
  fi

  # Resolved BEFORE removal: the view backend forgets the mapping once the
  # working environment is gone.
  local view_id=''
  if view_backend; then
    view_id=$(_view_on "$working_env" || true)
    [[ -n $view_id ]] || warn+=("view_not_open")
  fi

  # The caller's pane may be sitting inside the workspace of that checkout. Pull
  # it out before it disappears under its feet, or the very command that removed
  # it leaves the session running from a dead cwd. Best-effort: warn.
  [[ -n $view_id ]] && { _view_detach_caller "$view_id" || warn+=("view_detach_move_failed"); }

  if [[ $use_git_fallback == true ]]; then
    force_remove_checkout "$working_env" \
      || fail "working_environment_remove_failed" \
           "$(jq -nc --arg w "$working_env" '{workingEnvironment: $w}')"
  else
    wt "${args[@]}" >/dev/null 2>&1 \
      || fail "working_environment_remove_rejected" "$(jq -nc --arg b "$branch" '{branch: $b}')"
  fi

  # The toolchain reported success, so the directory has to be gone. If it is not,
  # `removed:true` would be a lie the caller acts on (it stops asking, stops
  # cleaning, and never learns the directory is still there), and a warning in a
  # field nobody reads is not a safety net. Fail loudly instead.
  if [[ -e $working_env ]]; then
    fail "working_environment_remove_incomplete" \
      "$(jq -nc --arg w "$working_env" \
           '{workingEnvironment: $w, hint: "removal reported success but the path survives"}')"
  fi

  jq -nc --arg branch "$branch" --arg workingEnvironment "$working_env" \
    --arg view_id "$view_id" \
    --argjson warnings "$(warnings_json)" \
    '{ok: true, removed: true, branch: $branch,
      workingEnvironment: $workingEnvironment,
      view_id: $view_id, warnings: $warnings}'
  exit 0
}
