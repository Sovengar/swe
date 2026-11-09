#!/usr/bin/env bash
# git.sh — the backend adapter. It answers "where is this branch checked out" and
# "remove that checkout", without depending on the view backend.
#
# This file is the ONLY place in the tree that knows git's own vocabulary
# (`git worktree list`, `git worktree remove`, `wt`). Every other module — and
# every agent, every JSON key and every failure reason — speaks
# `workingEnvironment`, which names the RUN's isolated checkout rather than the
# mechanism providing it. That is what makes the mechanism swappable: retiring
# git worktrees means rewriting this file, not the pipeline.
#
# Two probes are deliberately separate: a detached checkout has no branch, so a
# lookup by branch cannot see it even while it still holds a directory and
# possibly the only copy of a commit.

swe_source_once core.sh

# True when the current directory is a linked (secondary) checkout rather than
# the repository's primary one.
is_linked_checkout() {
  [[ "$(git rev-parse --git-dir 2>/dev/null)" != "$(git rev-parse --git-common-dir 2>/dev/null)" ]]
}

# Path of the primary checkout, even when invoked from inside a linked checkout.
primary_checkout() {
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$(dirname "$common")" && pwd -P)
}

# True when the caller sits inside a git repository. The command is git's own
# probe; callers only ever learn the boolean, never the vocabulary.
in_git_repository() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Canonical path checked out at BRANCH, empty when there is none.
# `git worktree list --porcelain` is used on purpose: `wt list --format=json` is
# mid-migration between two schemas and `jq select` breaks on the array form.
working_environment_for_branch() {
  local branch=$1 path=''
  while read -r line; do
    case $line in
      'worktree '*) path=${line#worktree } ;;   # git's porcelain record header
      "branch refs/heads/$branch") printf '%s\n' "$path"; return 0 ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  return 1
}

# Paths of the checkouts whose HEAD is detached, one per line. They are the blind
# spot of working_environment_for_branch: a detached checkout is on no branch, so
# a branch lookup cannot find it. Non-zero when there are none.
detached_working_environments() {
  local line path='' found=false
  while read -r line; do
    case $line in
      'worktree '*) path=${line#worktree } ;;   # git's porcelain record header
      detached)
        [[ -n $path ]] || continue
        printf '%s\n' "$path"
        found=true
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  [[ $found == true ]]
}

# Force-remove PATH through git directly. The verb layer calls this instead of
# `git worktree remove`, so the backend command stays confined here.
force_remove_checkout() { # <path>
  git worktree remove --force "$1"
}