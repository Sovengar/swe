#!/usr/bin/env bash
# git-forge.sh — the single concrete mechanism implementation behind the seam.
# This is the ONLY place that may name the underlying tools and the forge they
# talk to; it reports facts and never emits a public reason or verb name. It is
# exempt from the vocabulary guard by design (see the issue's scope note).

swe_source_once core.sh

# --- destination ------------------------------------------------------------

# Opaque repository identity: a stable digest of the origin URL, never the URL
# itself, so the public surface cannot leak where the change lives.
_repo_identity() {
  local remote=$1
  printf '%s' "$remote" | sha1sum | awk '{print $1}'
}

_forge_host() {
  local remote=$1
  remote=${remote#*://}; remote=${remote#*@}
  printf '%s' "${remote%%[/:]*}"
}

# First existing ref spelling of a base NAME, so a name that exists only as a
# remote-tracking ref still resolves. Prints the ref, else returns 1.
_forge_base_ref() { # <name>
  local name=$1 ref
  [[ -n $name ]] || return 1
  for ref in "refs/remotes/origin/$name" "refs/heads/$name" "$name"; do
    git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 && { printf '%s' "$ref"; return 0; }
  done
  return 1
}

# The integration base of this run, resolved from the repository itself and
# printed as "<name>\t<source>". One function, one answer: every verb that needs
# the base calls this, so the history-shaping side and the destination side
# cannot derive two different bases from the same tree. Precedence, most
# trustworthy first:
#
#   1. SWE_INTEGRATION_BASE — an explicit operator override; it wins outright.
#   2. swe-run-base         — the base declared for THIS run by `ensure`: the
#                             checkout it was invoked from (or an explicit
#                             --base), captured before the working environment
#                             existed. It is a file in the git dir, not an
#                             environment variable, because the verbs that read
#                             it run in later sessions that never shared the
#                             shell it was written in. A declared name that no
#                             longer resolves is a stale declaration, not a
#                             base: it is skipped and the resolution continues.
#   3. origin/HEAD          — git's own local record of the remote's default
#                             branch; no network needed, so it is trusted first.
#   4. upstream             — the current branch's tracking ref, but only when
#                             it names a DIFFERENT branch: an upstream that is
#                             the branch's own remote counterpart is not a base.
#   5. remote_default       — the remote's HEAD asked directly, only when the two
#                             local candidates are absent (network; best-effort).
#
# Everything that costs nothing is tried before anything that can cost seconds:
# `ls-remote` sits last on purpose. It cannot be memoized either (every caller
# reads the answer out of a command substitution, so a cached variable would die
# in the subshell), which makes its position the only lever on how often it runs.
#
# An unresolvable base is an error, never a guess. A wrong base does not produce
# a slightly-wrong diff: it folds the repository's own history into the change,
# silently. Returns 1 when no candidate resolves.
_forge_resolve_integration_base() {
  local base='' ref='' sym='' up='' up_branch='' cur='' gitdir='' runbase=''

  if [[ -n ${SWE_INTEGRATION_BASE:-} ]]; then
    printf '%s\tenvironment\n' "$SWE_INTEGRATION_BASE"
    return 0
  fi

  gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || gitdir=''
  if [[ -n $gitdir && -f "$gitdir/swe-run-base" ]]; then
    runbase=$(head -n1 "$gitdir/swe-run-base" 2>/dev/null) || runbase=''
    if [[ -n $runbase ]] && _forge_base_ref "$runbase" >/dev/null 2>&1; then
      printf '%s\trun_base\n' "$runbase"
      return 0
    fi
  fi

  ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=''
  case $ref in
    origin/*)
      base=${ref#origin/}
      if _forge_base_ref "$base" >/dev/null 2>&1; then
        printf '%s\torigin_head\n' "$base"; return 0
      fi ;;
  esac

  up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || up=''
  if [[ $up == */* ]]; then
    up_branch=${up#*/}
    cur=$(git branch --show-current 2>/dev/null) || cur=''
    if [[ $up_branch != "$cur" ]] && _forge_base_ref "$up_branch" >/dev/null 2>&1; then
      printf '%s\tupstream\n' "$up_branch"; return 0
    fi
  fi

  # Guarded: without a deadline the remote probe could hang, and a resolver that
  # hangs reports nothing at all. Skip it when no timeout binary exists.
  if command -v timeout >/dev/null 2>&1; then
    sym=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote --symref origin HEAD 2>/dev/null) || sym=''
    base=$(printf '%s\n' "$sym" | awk '$1=="ref:" && $3=="HEAD" {sub(/^refs\/heads\//,"",$2); print $2; exit}')
    if [[ -n $base ]] && _forge_base_ref "$base" >/dev/null 2>&1; then
      printf '%s\tremote_default\n' "$base"; return 0
    fi
  fi

  return 1
}

# The failure object for an unresolvable base, so every caller names the same
# candidates and the same error.
_forge_base_unknown_json() {
  jq -nc '{error: "INTEGRATION_BASE_UNKNOWN",
           searched: ["SWE_INTEGRATION_BASE", "swe-run-base", "origin/HEAD",
                      "upstream", "remote_default"]}'
}

# The destination repository alone. A PUSH needs to know WHERE to push, never
# which base to compare against: resolving a base here refuses a valid push in a
# repository whose default branch this clone does not know yet (a fresh remote,
# no `origin/HEAD`, no fetch) — a shape a shared run hits routinely.
mechanism_repository() {
  need jq
  local remote
  remote=$(git remote get-url origin 2>/dev/null) || remote=''
  if [[ -z $remote ]]; then
    printf '%s\n' '{"error":"REPOSITORY_UNKNOWN"}'
    return 1
  fi
  jq -nc --arg repository "$(_repo_identity "$remote")" '{repository: $repository}'
}

mechanism_destination() {
  need git
  local remote=''
  remote=$(git remote get-url origin 2>/dev/null) || remote=''
  if [[ -z $remote ]]; then
    _forge_base_unknown_json
    return 1
  fi
  local line base source repository
  line=$(_forge_resolve_integration_base) || { _forge_base_unknown_json; return 1; }
  base=${line%%$'\t'*}
  source=${line#*$'\t'}
  repository=$(_repo_identity "$remote")
  jq -nc --arg repository "$repository" --arg integration_base "$base" \
         --arg base_source "$source" \
    '{repository: $repository, integration_base: $integration_base,
      base_source: $base_source}'
}

# --- publication / change view ---------------------------------------------

# Emit a normalized change view for the current branch, or an error object.
mechanism_change_view() {
  need jq
  local branch payload
  branch=$(git branch --show-current 2>/dev/null) || branch=''
  payload=$(_forge_view "$branch" 2>/dev/null) || payload=''
  if [[ -z $payload ]]; then
    printf '%s\n' '{"error":"CHANGE_NOT_PUBLISHED"}'
    return 1
  fi
  printf '%s\n' "$payload"
}

# Shared publication: the change branch IS the integration branch, so making the
# change available is a push. No forge is consulted and no pull request exists,
# which is why this returns `change: null` and `state: pushed` instead of the PR
# shape. It still refuses a push that would send nothing: a branch level with its
# upstream is not a publication, and reporting success for it is a lie an agent
# then builds on.
mechanism_push() {
  need git
  local branch='' upstream='' ahead=''
  branch=$(git branch --show-current 2>/dev/null) || branch=''
  if [[ -z $branch ]]; then
    printf '%s\n' '{"error":"NO_CHANGE_BRANCH"}'
    return 1
  fi
  git remote get-url origin >/dev/null 2>&1 \
    || { printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1; }

  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=''
  if [[ -n $upstream ]]; then
    ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null) || ahead=''
    if [[ -n $ahead && $ahead -eq 0 ]]; then
      jq -nc --arg branch "$branch" --arg upstream "$upstream" \
        '{error: "NO_COMMITS_TO_PUBLISH", branch: $branch, upstream: $upstream}'
      return 1
    fi
  fi

  # The push's own chatter belongs on stderr: stdout carries exactly one JSON
  # line, and a caller reads it unfiltered.
  if ! GIT_TERMINAL_PROMPT=0 git push --set-upstream origin "$branch" >&2 2>&1; then
    printf '%s\n' '{"error":"PUBLISH_FAILED"}'
    return 1
  fi

  jq -nc --arg branch "$branch" --arg upstream "$upstream" \
         --argjson ahead "${ahead:-0}" '
    {change: null, state: "pushed", branch: $branch,
     upstream: (if $upstream == "" then null else $upstream end),
     commits_ahead: $ahead, open_for_integration: false,
     verification_state: "unknown"}'
}

mechanism_publish() { # <open:true|false> <issue-number|""
  need jq
  local open=$1 issue=${2:-} branch
  branch=$(git branch --show-current 2>/dev/null) || branch=''
  _forge_publish "$branch" "$open" "$issue"
}

# --- review ledger ----------------------------------------------------------
#
# The review loop's memory, kept where the run base already lives: a file in the
# working environment's git dir. It is the tree's own record, so a later round
# reads the loop's position instead of being told it, and it survives a session
# that forgot, compacted or resumed elsewhere.

_forge_ledger_file() { # → path, or 1 when this tree has no git dir
  local gitdir=''
  gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || gitdir=''
  [[ -n $gitdir ]] || return 1
  printf '%s/swe-review-ledger.json\n' "$gitdir"
}

# Where the tree stands right now plus the ledger the last finished round wrote.
# ONE call, so a driver never assembles the loop's position from two sources
# that could disagree. An absent ledger is `{}`: a change nobody reviewed yet is
# round 0, not an error.
mechanism_review_state() {
  need jq
  local file='' head='' ledger='{}'
  head=$(git rev-parse HEAD 2>/dev/null) || head=''
  file=$(_forge_ledger_file 2>/dev/null) || file=''
  if [[ -n $file && -f $file ]]; then
    ledger=$(jq -c . "$file" 2>/dev/null) || ledger='{}'
  fi
  jq -nc --arg head "$head" --argjson ledger "$ledger" '{head: $head, ledger: $ledger}'
}

# Stores the ledger object read from stdin. Atomic: a reader never sees a
# half-written ledger, and a failed write leaves the previous one in place.
mechanism_review_ledger_write() {
  need jq
  local file='' tmp='' ledger=''
  file=$(_forge_ledger_file 2>/dev/null) || { printf '{"error":"REPOSITORY_UNKNOWN"}\n'; return 1; }
  ledger=$(jq -c . 2>/dev/null) || { printf '{"error":"LEDGER_INVALID"}\n'; return 1; }
  tmp="$file.$$"
  printf '%s\n' "$ledger" >"$tmp" 2>/dev/null || { rm -f "$tmp"; printf '{"error":"LEDGER_WRITE_FAILED"}\n'; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; printf '{"error":"LEDGER_WRITE_FAILED"}\n'; return 1; }
  printf '{"stored":true}\n'
}

# --- integration policy -----------------------------------------------------

mechanism_integration_mode() {
  jq -nc '{mode: "linear"}'
}

mechanism_history_collapses() {
  jq -nc '{collapses: false}'
}

# --- history ----------------------------------------------------------------

# Conventional-commit subject -> "type<TAB>scope<TAB>subject" lines.
_history_steps() { # <base> <rev>
  local base=$1 rev=$2
  git log --reverse --format='%s' "$base..$rev" 2>/dev/null \
    | awk -F'[(:)]' '
        {
          subject=$0
          type=$1
          scope=""
          if (subject ~ /^[A-Za-z]+\([^)]*\)/) {
            match(subject, /\(([^)]*)\)/, m); scope=m[1]
          }
          printf "%s\t%s\t%s\n", type, scope, subject
        }'
}

mechanism_history_steps() { # <base> <rev>
  need git
  local base=$1 rev=$2
  local tsv
  tsv=$(_history_steps "$base" "$rev") || { printf '%s\n' '{"error":"HISTORY_REWRITE_FAILED"}'; return 1; }
  printf '%s' "$tsv" | jq -R -s -c '
    split("\n") | map(select(length>0) | split("\t"))
    | map({type: .[0], scope: .[1], subject: .[2]})
    | {steps: .}'
}

mechanism_history_state() {
  need git
  local head base protected=false unsaved=false branch line base_name base_ref
  head=$(git rev-parse HEAD 2>/dev/null) || { printf '%s\n' '{"error":"HISTORY_REWRITE_FAILED"}'; return 1; }
  branch=$(git branch --show-current 2>/dev/null) || branch=''
  # The base is resolved from the repository, and an unresolvable base is an
  # error. The old fallback to the root commit is exactly what let a repository
  # whose base is not the hardcoded one fold its own history into the change,
  # silently.
  line=$(_forge_resolve_integration_base) || { _forge_base_unknown_json; return 1; }
  base_name=${line%%$'\t'*}
  base_ref=$(_forge_base_ref "$base_name") || { _forge_base_unknown_json; return 1; }
  # The change is protected when it sits on the integration base itself, or on
  # one of the conventional integration names.
  case $branch in main|master|trunk|"$base_name") protected=true ;; esac
  if [[ -n $(git status --porcelain 2>/dev/null) ]]; then unsaved=true; fi
  base=$(git merge-base "$head" "$base_ref" 2>/dev/null) || {
    jq -nc --arg base "$base_name" \
      '{error: "INTEGRATION_BASE_UNKNOWN", base: $base,
        searched: ["merge-base with the resolved base"],
        hint: "the resolved base shares no history with HEAD"}'
    return 1
  }
  local steps
  steps=$(mechanism_history_steps "$base" "$head") || return 1
  jq -nc --arg head "$head" --arg base "$base" \
    --argjson unsaved "$unsaved" --argjson protected "$protected" \
    --argjson steps "$(printf '%s' "$steps" | jq '.steps')" \
    '{head: $head, base: $base, unsaved: $unsaved, protected: $protected, steps: $steps}'
}

mechanism_content_tree() { # <rev>
  git rev-parse "$1^{tree}" 2>/dev/null
}

mechanism_history_reset() { # <rev>
  git rebase --abort >/dev/null 2>&1 || true
  git reset --hard "$1" >/dev/null 2>&1
}

# Rewrites the change's history into the given groups. `plan` is JSON:
#   {"base": "<sha>", "groups": [{"members": [idx...], "message": "..."}]}
# Members are indexes into the oldest-first commit list of base..HEAD.
mechanism_history_rewrite() {
  need git
  local plan=$1 base head tree_before tmp
  base=$(printf '%s' "$plan" | jq -r '.base')
  head=$(git rev-parse HEAD)
  tree_before=$(git rev-parse 'HEAD^{tree}')
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  local -a shas=()
  local s
  while IFS= read -r s; do if [[ -n $s ]]; then shas+=("$s"); fi; done \
    < <(git log --reverse --format='%H' "$base..$head")

  : > "$tmp/roles"
  local g first members idx role
  local n_groups
  n_groups=$(printf '%s' "$plan" | jq '.groups | length')
  for ((g = 0; g < n_groups; g++)); do
    members=$(printf '%s' "$plan" | jq -r ".groups[$g].members[]")
    first=1
    for idx in $members; do
      [[ -n ${shas[$idx]:-} ]] || continue
      if [[ $first -eq 1 ]]; then role=head; first=0; else role=member; fi
      printf '%s %s\n' "${shas[$idx]}" "$role" >> "$tmp/roles"
    done
  done

  printf '%s' "$plan" | jq -r '.groups[].message' > "$tmp/queue"

  cat > "$tmp/seq" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
todo=$1
out=$(mktemp)
while IFS= read -r line; do
  set -- $line
  case ${1:-} in
    pick|reword|edit|squash|fixup|drop) ;;
    *) printf '%s\n' "$line" >> "$out"; continue ;;
  esac
  sha=${2:-}
  full=$(git rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null || printf '%s' "$sha")
  role=$(awk -v s="$full" '$1==s{print $2; exit}' "${ROLE_FILE:-/dev/null}")
  case $role in
    head)   printf 'reword %s\n' "$sha" >> "$out" ;;
    member) printf 'fixup %s\n' "$sha" >> "$out" ;;
    *)      printf 'pick %s\n' "$sha" >> "$out" ;;
  esac
done < "$todo"
mv "$out" "$todo"
EOS

  cat > "$tmp/msg" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
msgfile=$1
first=$(head -n1 "${QUEUE_FILE:-/dev/null}")
if [[ -n ${QUEUE_FILE:-} && -s ${QUEUE_FILE:-/dev/null} ]]; then
  tail -n +2 "$QUEUE_FILE" > "$QUEUE_FILE.tmp"
  mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
fi
printf '%s\n' "$first" > "$msgfile"
EOS
  chmod +x "$tmp/seq" "$tmp/msg"

  local newhead
  if GIT_SEQUENCE_EDITOR="$tmp/seq" GIT_EDITOR="$tmp/msg" \
     ROLE_FILE="$tmp/roles" QUEUE_FILE="$tmp/queue" \
     git rebase -i --autostash "$base" >/dev/null 2>&1; then
    newhead=$(git rev-parse HEAD)
  else
    git rebase --abort >/dev/null 2>&1 || true
    git reset --hard "$head" >/dev/null 2>&1 || true
    printf '%s\n' '{"error":"HISTORY_REWRITE_FAILED"}'
    return 1
  fi

  local tree_after
  tree_after=$(git rev-parse 'HEAD^{tree}')
  jq -nc --arg head "$newhead" --arg tree "$tree_after" --arg before "$tree_before" \
    '{head: $head, tree: $tree, tree_before: $before}'
}

mechanism_republish() { # <rev>
  need git
  git push --force-with-lease origin "HEAD:$(git branch --show-current)" >/dev/null 2>&1 \
    || { printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1; }
  jq -nc '{change: "refreshed"}'
}

# --- integration ------------------------------------------------------------

# The PR number, captured while the branch still exists.
#
# It has to be captured BEFORE the merge and used AFTER it, because a merge that
# deletes the branch leaves nothing to resolve by name: `gh pr view <branch>`
# then fails, and post-merge verification would have no subject.
_forge_pr_number() { # <branch>
  local remote host kind
  remote=$(git remote get-url origin 2>/dev/null) || return 1
  host=$(_forge_host "$remote")
  kind=$(_forge_kind "$remote")
  case $kind in
    github)
      GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
        gh pr view "$1" --json number -q .number 2>/dev/null
      ;;
    gitlab)
      GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
        glab api "projects/:id/merge_requests?source_branch=$1&state=opened" 2>/dev/null \
        | jq -r '.[0].iid // empty'
      ;;
    *) return 1 ;;
  esac
}

# Whether the change actually landed, asked of the change itself and of nobody
# else. Answers by number so it survives the branch's deletion.
_forge_pr_merged() { # <pr-number>
  local remote host kind
  remote=$(git remote get-url origin 2>/dev/null) || return 1
  host=$(_forge_host "$remote")
  kind=$(_forge_kind "$remote")
  case $kind in
    github)
      [[ $(GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
            gh pr view "$1" --json state -q .state 2>/dev/null) == MERGED ]]
      ;;
    gitlab)
      [[ $(GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
            glab api "projects/:id/merge_requests/$1" 2>/dev/null \
            | jq -r '.state // empty') == merged ]]
      ;;
    *) return 1 ;;
  esac
}

mechanism_integrate() { # <rev>
  need jq
  local view state comp branch pr
  view=$(mechanism_change_view 2>/dev/null) || view=''
  state=$(printf '%s' "$view" | jq -r '.state // "proposed"')
  if [[ $state == integrated ]]; then
    jq -nc '{state: "integrated", noop: true}'
    return 0
  fi
  branch=$(git branch --show-current 2>/dev/null) || branch=''
  # Three cases, not two: a computed conflict does not resolve itself, a
  # not-yet-computed state is transient, and only a ready change is attempted.
  comp=$(_forge_merge_state "$branch")
  case $comp in
    conflict) printf '%s\n' '{"error":"conflict"}'; return 1 ;;
    pending)  printf '%s\n' '{"error":"pending"}'; return 1 ;;
  esac
  pr=$(_forge_pr_number "$branch" 2>/dev/null) || pr=''
  # A non-zero exit from the merge command is NOT evidence that the merge did not
  # happen. `gh pr merge --delete-branch` merges first and cleans up after, and
  # the cleanup exits non-zero whenever the branch is checked out in a linked
  # checkout — which, in this harness, is always. The old reasoning here ("only a
  # genuine attempt that failed is transient") had that backwards: such a failure
  # is neither transient nor a statement about the merge. It reports
  # INTEGRATION_FAILED
  # with `partial: true` on a merge that landed, and the caller is left believing
  # an irreversible step failed when it succeeded.
  #
  # So: when the command reports failure, ask the change whether it landed. The
  # PR's own state is the fact; the exit code is only a report about a command
  # that does two things.
  if ! _forge_merge "$1" >/dev/null 2>&1; then
    if [[ -n $pr ]] && _forge_pr_merged "$pr"; then
      : # The merge landed. Only gh's local branch cleanup failed, and cleanup is
        # this harness's other job — reporting a failure here would send the
        # caller hunting for a merge that already exists.
    else
      printf '%s\n' '{"error":"INTEGRATION_FAILED","partial": true}'
      return 1
    fi
  fi
  jq -nc '{state: "integrated", noop: false}'
}

# The change's compatibility with its base, as a tri-state fact:
#   ready    — the change applies cleanly right now
#   conflict — the forge computed a conflict; it needs a human
#   pending  — the forge has not computed it yet (unknown/in progress)
# A not-yet-computed state is NEVER reported as a conflict.
mechanism_integration_compatibility() {
  local state
  state=$(_forge_merge_state "$(git branch --show-current 2>/dev/null)")
  jq -nc --arg compatibility "$state" '{compatibility: $compatibility}'
}

# --- cleanup ----------------------------------------------------------------

# The branch is an ARGUMENT, never the caller's cwd. The closer is the one agent
# that must sit OUTSIDE the working environment (its own session guard refuses
# otherwise), and from there `--show-current` names the base, not the change: it
# removed the base and answered ok:true with two risks nobody reads. An empty
# branch is an error here rather than a guess, because `git branch -D ""` fails
# for a reason that has nothing to do with what went wrong.
mechanism_cleanup() { # <branch>
  need git
  local branch=${1:-}
  if [[ -z $branch ]]; then
    printf '%s\n' '{"error":"CLEANUP_BRANCH_UNKNOWN"}'
    return 1
  fi
  local -a cleaned=() risks=()
  local _lines_to_json='split("\n") | map(select(length>0))'
  if git fetch --prune origin >/dev/null 2>&1; then cleaned+=("pruned_remote_tracking")
  else risks+=("prune_failed"); fi

  # No repo probe here: `remove` owns that refusal (`not_a_git_repository`), so a
  # caller outside a repository gets a reason that names the real problem instead
  # of a skip that reads as "there was nothing to clean".
  local out rc=0
  out=$("$SWE_HOME/swe.sh" remove --branch "$branch" --force-delete 2>/dev/null) || rc=$?
  if [[ $rc -ne 0 ]]; then
    local reason
    reason=$(printf '%s' "$out" | jq -r '.reason // "unknown"')
    if [[ $reason == session_inside_working_environment ]]; then
      jq -nc --argjson out "$out" '{session_inside_working_environment: $out}'
      return 0
    fi
    risks+=("remove_$reason")
  elif [[ $(printf '%s' "$out" | jq -r '.removed // false') != true ]]; then
    # `remove` answers ok:true with removed:false when the branch has no checkout:
    # the right goal state for a retry, but a cleanup that claims it released a
    # workspace after releasing nothing is a green that measured nothing.
    risks+=("nothing_to_release")
  else
    cleaned+=("workspace_released")
  fi
  if git branch -D "$branch" >/dev/null 2>&1; then cleaned+=("local_change_removed")
  else risks+=("local_branch_delete_failed"); fi

  jq -nc --argjson cleaned "$(printf '%s\n' "${cleaned[@]-}" | jq -R -s "$_lines_to_json")" \
         --argjson risks "$(printf '%s\n' "${risks[@]-}" | jq -R -s "$_lines_to_json")" \
    '{cleaned: $cleaned, risks: $risks}'
}

# --- CI verification --------------------------------------------------------

# The verdict vocabulary is the one the change view already used, so a caller
# never has to learn two classifications of the same thing:
#
#   none     — the change has no checks at all
#   passing  — every check finished and none failed
#   failing  — a check finished and failed (or was cancelled)
#   pending  — a check has not finished yet
#
# This jq program is the ONLY classifier in the file, held as text so both
# callers run the same code: duplicating it would let the merge gate and the
# await-ci verb disagree about the same run, which is precisely the failure this
# indirection exists to prevent. It deliberately keeps the rule the view already
# had: only an explicit failure or cancellation is `failing`. Everything else
# that completed counts as passing — including the conclusions nobody wants to
# see in a merge gate (timed_out, action_required, stale, neutral, skipped).
# Widening the rule here would silently change what `ready-to-integrate`
# accepts, which is a separate decision with its own blast radius, so those
# conclusions are surfaced as `soft_failures` instead of being judged silently.
_FORGE_CI_VERDICT_JQ='
  # `id` survives the normalization on purpose: the wait needs something to block
  # on. It is the mechanism'"'"'s own field (null for the change view, which reads
  # checks that have no run to watch) and the domain verb drops it before
  # publishing. Normalizing it away broke the wait in a way that looked like a
  # timeout: nothing was pending because nothing was ever watched.
  def checks:
    [.[] | {id: (.id // null),
            name: (.name // "?"),
            status: (.status // "?"),
            conclusion: (if (.conclusion // "") == "" or .conclusion == null
                         then null else .conclusion end)}];
  checks as $checks
  | ($checks | length) as $total
  | ([$checks[] | select(.status != "completed")] | length) as $pending
  | {
      total: $total,
      pending: $pending,
      results: $checks,
      suspicious: ([$checks[]
        | select(.status == "completed")
        | select(.conclusion != null
                 and .conclusion != "success"
                 and .conclusion != "neutral"
                 and .conclusion != "skipped")
        | {name: .name, conclusion: .conclusion}]),
      state: (if $total == 0 then "none"
              elif ([$checks[] | select(.conclusion == "failure" or .conclusion == "cancelled")] | length) > 0 then "failing"
              elif $pending > 0 then "pending"
              else "passing" end)
    }
  | .passing = (.state == "passing")
  | .failing = (.state == "failing")
'

# Classify a JSON array of checks (on stdin) into the verdict.
_forge_ci_verdict() { jq -c "$_FORGE_CI_VERDICT_JQ"; }

# Take an object that carries a `checks` array and return it with that array
# replaced by the verdict. Both the change view and mechanism_verification_snapshot build
# their object the same way and come through here, so the classification is
# literally the same jq run.
#
# The whole object is slurped FIRST, before any jq runs. Reading the `checks`
# field off stdin and then running a second jq on the same stdin looks fine and
# is not: the first jq drained the pipe and the second one read nothing, so the
# function returned an empty string with a success status — a silent no-output
# that the caller cannot tell from a real answer.
_forge_ci_attach_verdict() { # reads one object on stdin
  local object checks verdict
  object=$(cat 2>/dev/null) || return 1
  [[ -n $object ]] || return 1
  checks=$(printf '%s' "$object" | jq -c '(.checks // [])' 2>/dev/null) || return 1
  verdict=$(printf '%s' "$checks" | _forge_ci_verdict 2>/dev/null) || return 1
  [[ -n $verdict ]] || return 1
  printf '%s' "$object" | jq -c --argjson verdict "$verdict" 'del(.checks) + $verdict'
}

# Same, but nesting the verdict under `verification` — the shape the change view
# has always published, and therefore the shape every existing caller reads.
_forge_ci_verification_field() { # reads one object on stdin
  local object checks verdict
  object=$(cat 2>/dev/null) || return 1
  [[ -n $object ]] || return 1
  checks=$(printf '%s' "$object" | jq -c '(.checks // [])' 2>/dev/null) || return 1
  verdict=$(printf '%s' "$checks" | _forge_ci_verdict 2>/dev/null) || return 1
  [[ -n $verdict ]] || return 1
  # `del(.checks)` keeps the view's own fields untouched, so the view's `state`
  # (proposed/integrated/withdrawn) can never be overwritten by the verdict's
  # `state` (passing/failing/pending). They are different facts that happen to
  # share a name, which is exactly why the verdict goes UNDER `verification`.
  printf '%s' "$object" | jq -c --argjson v "$verdict" \
    'del(.checks) as $rest | $rest + {verification: ($v + {detail: ""})}'
}

# Runs of the CURRENT head, read by sha and not only by branch name: a branch
# name outlives the commit it was pushed from, so filtering on the name alone
# reports the verdict of a push that no longer exists.
_forge_ci_runs_github() { # <branch>
  local branch=$1 sha=''
  sha=$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || sha=''
  if [[ -z $sha ]]; then
    printf 'null\n'
    return 1
  fi
  GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
    gh run list --branch "$branch" --limit 100 \
      --json databaseId,workflowName,status,conclusion,headSha 2>/dev/null \
    | jq -c --arg sha "$sha" '
        [ .[] | select(.headSha == $sha)
             | {name: .workflowName, status: .status,
                conclusion: (if .conclusion == "" then null else .conclusion end),
                id: .databaseId} ]' 2>/dev/null
}

_forge_ci_runs_gitlab() { # <branch>
  local remote host branch=$1
  remote=$(git remote get-url origin 2>/dev/null) || return 1
  host=$(_forge_host "$remote")
  # Same source the change view reads the verdict from, so the two cannot
  # disagree: the MR's head pipeline, not a second pipeline query.
  local raw=''
  raw=$(GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
    glab api "projects/:id/merge_requests?source_branch=$branch" 2>/dev/null) || raw=''
  [[ -n $raw ]] || return 1
  jq -c --arg host "$host" --arg branch "$branch" '
    ( [ .[] | select(.source_branch == $branch) ] | first ) as $mr
    | if $mr == null then null
      elif $mr.head_pipeline == null then []
      else [ {name: ($mr.head_pipeline.ref // "pipeline"),
               status: (if $mr.head_pipeline.status == "success"
                         or $mr.head_pipeline.status == "failed"
                         or $mr.head_pipeline.status == "canceled" then "completed"
                         else "in_progress" end),
               conclusion: (if $mr.head_pipeline.status == "success" then "success"
                            elif $mr.head_pipeline.status == "failed" then "failure"
                            elif $mr.head_pipeline.status == "canceled" then "cancelled"
                            else null end)} ]
      end' <<<"$raw" 2>/dev/null
}

# mechanism_verification_snapshot → the verification verdict of the change on the
# current line of work, read once.
mechanism_verification_snapshot() {
  need jq
  local remote branch kind runs
  remote=$(git remote get-url origin 2>/dev/null) || remote=''
  [[ -n $remote ]] || { printf '%s\n' '{"error":"VERIFICATION_NO_REPOSITORY"}'; return 1; }
  kind=$(_forge_kind "$remote") || { printf '%s\n' '{"error":"VERIFICATION_MECHANISM_UNSUPPORTED"}'; return 1; }
  branch=$(git branch --show-current 2>/dev/null) || branch=''
  runs=''
  case $kind in
    github) runs=$(_forge_ci_runs_github "$branch") || runs='' ;;
    gitlab) runs=$(_forge_ci_runs_gitlab "$branch") || runs='' ;;
  esac
  # An unreadable run list is NOT `none`. `none` means "this change has no
  # checks"; "I could not read them" is a different fact and must not be read as
  # a green light, so it is its own error.
  [[ -n $runs ]] || { printf '%s\n' '{"error":"VERIFICATION_MECHANISM_UNREADABLE"}'; return 1; }
  jq -nc --argjson checks "$runs" '{checks: $checks}' | _forge_ci_attach_verdict
}

# mechanism_verification_wait <deadline-seconds> → block until no check is pending, or the
# deadline passes, then report the verdict exactly as the snapshot does.
#
# The two forges need different blocking commands and that asymmetry is real,
# not incidental: `gh run watch` watches ONE run and needs its id, so a branch
# with three workflows means three calls; `glab ci status --live` resolves the
# pipeline itself. What both paths share is the final answer: the wait is only
# ever a way to make the READ happen later. The verdict is never taken from the
# blocking command's output, because that output is not JSON.
mechanism_verification_wait() { # <deadline-seconds>
  need jq
  local deadline=${1:-600}
  local snap remote branch kind started now remaining
  started=$(date +%s)
  remote=$(git remote get-url origin 2>/dev/null) || remote=''
  [[ -n $remote ]] || { printf '%s\n' '{"error":"VERIFICATION_NO_REPOSITORY"}'; return 1; }
  kind=$(_forge_kind "$remote") || { printf '%s\n' '{"error":"VERIFICATION_MECHANISM_UNSUPPORTED"}'; return 1; }
  branch=$(git branch --show-current 2>/dev/null) || branch=''

  # A deadline that cannot be enforced is not a deadline. Without a timeout
  # binary the wait would be unbounded, and an unbounded wait in an agent that
  # cannot ask questions is a hang that reports nothing.
  local timeout_bin=''
  for c in timeout gtimeout; do
    if command -v "$c" >/dev/null 2>&1; then timeout_bin=$c; break; fi
  done
  [[ -n $timeout_bin ]] || { printf '%s\n' '{"error":"VERIFICATION_WAIT_NO_DEADLINE"}'; return 1; }

  while :; do
    snap=$(mechanism_verification_snapshot) || { printf '%s\n' "$snap"; return 1; }
    [[ $(printf '%s' "$snap" | jq -r '.pending') == 0 ]] && break
    now=$(date +%s); remaining=$((deadline - (now - started)))
    if ((remaining <= 0)); then
      # `error` is what makes this a FAILURE and not a result. Returning the
      # payload with a non-zero status and no marker let the verb read it as a
      # successful answer — so a wait that timed out was reported as `ok: true`
      # with `timed_out: true` inside it, which is a caller trap: the one field
      # that says the answer is missing is the one nobody checks.
      printf '%s\n' "$snap" | jq -c --argjson waited "$((now - started))" \
        '{error: "VERIFICATION_WAIT_TIMEOUT", timed_out: true, waited_seconds: $waited} + .'
      return 1
    fi
    case $kind in
      github)
        # The ids come from the snapshot's own `results`. Reading `.checks` here
        # silently yields nothing: the verdict publishes `results`, so the join is
        # empty, no run is ever watched, and the wait degrades into spinning until
        # the deadline — indistinguishable from a CI that simply takes too long.
        local ids
        ids=$(printf '%s' "$snap" | jq -r '[.results[] | select(.status != "completed") | .id | select(. != null)] | join(" ")')
        local id
        for id in $ids; do
          now=$(date +%s); remaining=$((deadline - (now - started)))
          ((remaining > 0)) || break
          # `--exit-status` is what makes the wait terminate on failure instead
          # of on success; the verdict itself is re-read by the next snapshot.
          "$timeout_bin" "$remaining" env GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
            gh run watch "$id" --exit-status --interval 5 >/dev/null 2>&1 || true
        done
        ;;
      gitlab)
        "$timeout_bin" "$remaining" env GITLAB_HOST="${GITLAB_HOST:-$(_forge_host "$remote")}" GIT_TERMINAL_PROMPT=0 \
          glab ci status --live >/dev/null 2>&1 || true
        ;;
    esac
  done

  now=$(date +%s)
  printf '%s\n' "$snap" | jq -c --argjson waited "$((now - started))" \
    '{timed_out: false, waited_seconds: $waited} + .'
}

# --- forge adapter (internal; the only place the tools are named) ------------

_forge_kind() {
  local host
  host=$(_forge_host "$1")
  case $host in
    *github*) printf 'github\n' ;;
    *gitlab*) printf 'gitlab\n' ;;
    *)
      # A host that names neither forge is still GitLab when the operator said
      # so: GITLAB_HOST is glab's own override, and a self-hosted instance lives
      # on an address that carries no "gitlab" in it.
      if [[ -n ${GITLAB_HOST:-} ]]; then printf 'gitlab\n'; else printf 'unknown\n'; fi
      ;;
  esac
}

# Raw compatibility of the change with its base, tri-state: ready | conflict |
# pending. Only an explicit computed conflict is `conflict`; anything the forge
# has not computed (UNKNOWN, checking, unchecked, unreadable) is `pending`.
_forge_merge_state() { # <branch>
  local remote host kind
  remote=$(git remote get-url origin 2>/dev/null) || { printf 'pending\n'; return 0; }
  host=$(_forge_host "$remote")
  kind=$(_forge_kind "$remote")
  case $kind in
    github)
      local m=''
      m=$(GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
          gh pr view "$1" --json mergeable -q .mergeable 2>/dev/null) || m=''
      case $m in
        MERGEABLE)   printf 'ready\n' ;;
        CONFLICTING) printf 'conflict\n' ;;
        *)           printf 'pending\n' ;;
      esac
      ;;
    gitlab)
      local st=''
      st=$(GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
           glab api "projects/:id/merge_requests?source_branch=$1" 2>/dev/null \
           | jq -r '.[0].merge_status // empty') || st=''
      case $st in
        can_be_merged)      printf 'ready\n' ;;
        cannot_be_merged)   printf 'conflict\n' ;;
        *)                  printf 'pending\n' ;;
      esac
      ;;
    *) printf 'pending\n' ;;
  esac
}

_forge_view() { # <branch>
  local remote host kind
  remote=$(git remote get-url origin 2>/dev/null) || return 1
  host=$(_forge_host "$remote")
  kind=$(_forge_kind "$remote")
  case $kind in
    github)
      GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
        gh pr view "$1" --json number,state,isDraft,mergeable,reviewDecision,reviews,statusCheckRollup 2>/dev/null \
        | jq -c '{
            change: (.number|tostring),
            state: (if .state=="MERGED" then "integrated" elif .state=="CLOSED" then "withdrawn" else "proposed" end),
            open_for_integration: (.isDraft|not),
            integratable: (.mergeable=="MERGEABLE"),
            requested_changes: (.reviewDecision=="CHANGES_REQUESTED"),
            endorsements: ([.reviews[]? | select(.state=="APPROVED")] | length),
            checks: [ (.statusCheckRollup[]? // empty)
              | {name: (.name // .context // "?"),
                 status: (if .status == "COMPLETED" then "completed" else "queued" end),
                 conclusion: (if (.conclusion // "") == "" then null
                              else (.conclusion | ascii_downcase) end)}
            ]
          }' 2>/dev/null \
        | _forge_ci_verification_field
      ;;
    gitlab)
      local mr iid approvals
      mr=$(GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
        glab api "projects/:id/merge_requests?source_branch=$1" 2>/dev/null) || return 1
      iid=$(printf '%s' "$mr" | jq -r '.[0].iid // empty' 2>/dev/null) || iid=''
      [[ -n $iid ]] || return 1
      # `.approvals` is NOT part of the merge-request payload; the approvals
      # endpoint is the real source. If it cannot be read, endorsements is
      # explicitly null rather than a silent 0.
      local raw=''
      raw=$(GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
        glab api "projects/:id/merge_requests/$iid/approvals" 2>/dev/null) || raw=''
      if [[ -n $raw ]]; then
        approvals=$(printf '%s' "$raw" | jq '[.approved_by[]?] | length' 2>/dev/null) || approvals=null
      else
        approvals=null
      fi
      printf '%s' "$mr" | jq -c --argjson endorsements "$approvals" '.[0] | {
            change: (.iid|tostring),
            state: (if .state=="merged" then "integrated" elif .state=="closed" then "withdrawn" else "proposed" end),
            open_for_integration: (.draft|not),
            integratable: (.merge_status=="can_be_merged"),
            requested_changes: (.blocking_discussions_resolved|not),
            endorsements: $endorsements,
            checks: (if .head_pipeline == null then []
              else [ {name: (.head_pipeline.ref // "pipeline"),
                      status: (if .head_pipeline.status == "success" or .head_pipeline.status == "failed" or .head_pipeline.status == "canceled" then "completed" else "in_progress" end),
                      conclusion: (if .head_pipeline.status == "success" then "success"
                                   elif .head_pipeline.status == "failed" then "failure"
                                   elif .head_pipeline.status == "canceled" then "cancelled"
                                   else null end)} ] end)
          }' 2>/dev/null \
        | _forge_ci_verification_field
      ;;
    *) return 1 ;;
  esac
}

# --- issue publication -------------------------------------------------------

# Opens one tracked issue in the destination repository and reports it by
# number and address. Idempotency is NOT this function's job: it creates what it
# is asked to create, and the caller owns the "already published" question. The
# address is internal here (the caller stores it); the failure object never
# carries it, so a public reason stays a reason.
mechanism_open_issue() { # <title> <body-file>
  need jq
  local title=$1 body_file=$2 remote host kind out url number
  remote=$(git remote get-url origin 2>/dev/null) || {
    printf '%s\n' '{"error":"REPOSITORY_UNKNOWN"}'; return 1; }
  host=$(_forge_host "$remote")
  kind=$(_forge_kind "$remote")
  case $kind in
    github)
      out=$(GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
        gh issue create --title "$title" --body-file "$body_file" 2>/dev/null) || out=''
      ;;
    gitlab)
      # The body travels as a file, never in argv: a description is the one
      # argument that can outgrow the kernel's limit or collide with a flag.
      out=$(GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
        glab issue create --title "$title" --description-file "$body_file" -y 2>/dev/null) || out=''
      ;;
    *)
      printf '%s\n' '{"error":"ISSUE_MECHANISM_UNSUPPORTED"}'; return 1 ;;
  esac
  # The address is the preferred fact, but not a required one: glab prints
  # "✓ Created issue #7" and no URL at all. Deriving the number from the output
  # instead of from the URL is what keeps a URL-less success from being reported
  # as a failure and retried into a duplicate.
  url=$(printf '%s' "$out" | grep -Eo 'https?://[^[:space:]]+' | tail -n1) || url=''
  number=''
  if [[ -n $url ]]; then
    number=${url##*/}
    [[ $number =~ ^[0-9]+$ ]] || number=''
  fi
  if [[ -z $number ]]; then
    number=$(printf '%s' "$out" | grep -Eo '#[0-9]+' | head -n1) || number=''
    number=${number#\#}
  fi
  [[ -n $number ]] || { printf '%s\n' '{"error":"ISSUE_CREATE_FAILED"}'; return 1; }
  jq -nc --arg forge "$kind" --arg url "$url" --arg number "$number" \
    '{ok: true, forge: $forge,
      url: (if $url == "" then null else $url end),
      number: ($number | tonumber)}'
}

# Closes one tracked item, by the number the publishing verb recorded. Like the
# opening counterpart it reports facts and never decides: whether an item should
# be closed is the caller's question, and a tracker that refuses is a warning
# there, never a failed integration here.
mechanism_close_issue() { # <number>
  need jq
  local number=$1 remote host kind
  [[ $number =~ ^[0-9]+$ ]] || { printf '%s\n' '{"error":"ISSUE_NUMBER_INVALID"}'; return 1; }
  remote=$(git remote get-url origin 2>/dev/null) || {
    printf '%s\n' '{"error":"REPOSITORY_UNKNOWN"}'; return 1; }
  host=$(_forge_host "$remote")
  kind=$(_forge_kind "$remote")
  case $kind in
    github)
      GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
        gh issue close "$number" >/dev/null 2>&1 \
        || { printf '%s\n' '{"error":"ISSUE_CLOSE_FAILED"}'; return 1; }
      ;;
    gitlab)
      GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
        glab issue close "$number" >/dev/null 2>&1 \
        || { printf '%s\n' '{"error":"ISSUE_CLOSE_FAILED"}'; return 1; }
      ;;
    *) printf '%s\n' '{"error":"ISSUE_MECHANISM_UNSUPPORTED"}'; return 1 ;;
  esac
  jq -nc --arg forge "$kind" --argjson number "$number" \
    '{ok: true, forge: $forge, number: $number}'
}

_forge_publish() { # <branch> <open> <issue-number|""
  local branch=$1 open=$2 issue=${3:-} remote host kind body=''
  remote=$(git remote get-url origin 2>/dev/null) || { printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1; }
  host=$(_forge_host "$remote")
  kind=$(_forge_kind "$remote")
  # The same resolver the destination and history verbs use, so the base a
  # change is published against is the base the rest of the run computed.
  local line base
  line=$(_forge_resolve_integration_base) || { _forge_base_unknown_json; return 1; }
  base=${line%%$'\t'*}

  # A change is published FROM a change branch INTO the integration base. Two
  # shapes make that impossible, and the forge's own refusal is useless to a
  # caller: `gh pr create --base main --head main` fails, so the domain can only
  # report PUBLISH_FAILED and an agent reads that as transient and retries.
  # Name the real condition here, where it is still provable.
  if [[ -z $branch || $branch == "$base" ]]; then
    jq -nc --arg branch "$branch" --arg base "$base" \
      '{error: "CHANGE_BRANCH_IS_BASE", branch: $branch, integration_base: $base}'
    return 1
  fi
  # A branch with no commit over the base is not a change either: the push would
  # be a no-op and the pull request would carry the base's own history.
  local ahead=''
  ahead=$(git rev-list --count "$base..$branch" 2>/dev/null) || ahead=''
  if [[ -n $ahead && $ahead -eq 0 ]]; then
    jq -nc --arg branch "$branch" --arg base "$base" \
      '{error: "NO_COMMITS_TO_PUBLISH", branch: $branch, integration_base: $base}'
    return 1
  fi
  # The link back to the tracked item is written HERE, in the body, because that
  # is the only place the tracker reads a closing reference. No item, no link: an
  # empty body stays empty instead of carrying a dangling keyword.
  [[ -n $issue ]] && body="Closes #$issue"
  case $kind in
    github)
      if GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
           gh pr view "$branch" --json number >/dev/null 2>&1; then
        # Already proposed. The body is refreshed only when there is a link to
        # add, and a failure here is not a failed publication: the change is
        # open and re-stating its body is an improvement, not the act itself.
        if [[ -n $body ]]; then
          GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
            gh pr edit "$branch" --body "$body" >/dev/null 2>&1 || true
        fi
      else
        GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
          gh pr create --draft --base "$base" --head "$branch" \
            --title "$branch" --body "$body" >/dev/null 2>&1 \
        || { printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1; }
      fi
      if [[ $open == true ]]; then
        GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 gh pr ready "$branch" >/dev/null 2>&1 \
          || { printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1; }
      fi
      ;;
    gitlab)
      if GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
           glab mr view "$branch" >/dev/null 2>&1; then
        if [[ -n $body ]]; then
          GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
            glab mr update "$branch" -d "$body" >/dev/null 2>&1 || true
        fi
      else
        GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
          glab mr create --draft -b "$base" -s "$branch" -t "$branch" -d "$body" -y >/dev/null 2>&1 \
        || { printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1; }
      fi
      if [[ $open == true ]]; then
        GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 glab mr update "$branch" --ready >/dev/null 2>&1 \
          || { printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1; }
      fi
      ;;
    *) printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1 ;;
  esac
  local view
  view=$(mechanism_change_view) || { printf '%s\n' '{"error":"PUBLISH_FAILED"}'; return 1; }
  # `verification_state` rides along so the domain can warn at publication time
  # about a change nothing will ever verify — the moment the warning is still
  # cheap to act on, instead of the close.
  printf '%s\n' "$view" \
    | jq -c '{change, state, open_for_integration,
              verification_state: (.verification.state // "unknown")}'
}

_forge_merge() { # <rev>
  local branch remote kind host
  branch=$(git branch --show-current 2>/dev/null) || return 1
  remote=$(git remote get-url origin 2>/dev/null) || return 1
  host=$(_forge_host "$remote")
  kind=$(_forge_kind "$remote")
  case $kind in
    github)
      GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
        gh pr merge --rebase --match-head-commit "$1" --delete-branch "$branch" >/dev/null 2>&1 ;;
    gitlab)
      GITLAB_HOST="${GITLAB_HOST:-$host}" GIT_TERMINAL_PROMPT=0 \
        glab mr merge "$branch" --yes --auto-merge=false --sha "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
