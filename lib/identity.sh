#!/usr/bin/env bash
# identity.sh — the run's identity vocabulary, shared by the two verbs that have
# to agree on it: `ensure` names a run, `resolve` reconstructs it from the branch
# alone. Keeping both sides here is what lets each of them stay independent of
# the other instead of sourcing each other.

swe_source_once core.sh

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

# The planning directory must be STABLE for a given branch: on resume the
# orchestrator calls ensure again and has to get the same path the planner
# already wrote into, or the artifacts split across two directories. So an
# existing directory for this exact type+slug always wins over a fresh number,
# and {NNNN} is only allocated when there is none.
#
# Shared by ensure and resolve on purpose. If the two ever disagreed, resolve
# would hand a child a path that no other step of the run knows about — a
# failure that looks like success from inside the child.
planning_dir_for() { # <workingEnvironment> <type> <slug>
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
