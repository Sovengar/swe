#!/usr/bin/env bash
# view.sh — the optional visual surface and its teardown. This backend is an
# implementation detail of the manager: callers never see it, and every command
# still succeeds with an empty view_id when no backend is available.

swe_source_once core.sh git.sh

# The visual surface is optional. When it is unavailable every subcommand still
# does its real job; view_id comes back empty and the caller carries on.
view_backend() { [[ ${HERDR_ENV:-} == 1 ]] && command -v herdr >/dev/null 2>&1; }

# --- view backend plumbing (never surfaced to callers) ----------------------

_view_repo_root() {
  local root
  root=$(herdr worktree list --cwd "$PWD" --json 2>/dev/null \
    | jq -r '.result.source.repo_root // empty' 2>/dev/null) || root=''
  [[ -n $root ]] && { printf '%s\n' "$root"; return 0; }
  primary_checkout
}

# View already attached to PATH, empty when the working environment is not visible yet.
_view_on() {
  local wt=$1
  herdr worktree list --cwd "$(_view_repo_root)" --json 2>/dev/null \
    | jq -r --arg p "$wt" \
        '.result.worktrees[]? | select(.path == $p) | .open_workspace_id // empty' \
    2>/dev/null | head -n1
}

# Open a new workspace for the checkout at PATH, labelled LABEL. Prints the new
# id on stdout and returns the BACKEND's exit status, so the caller can still tell
# "the backend refused" from "the backend said ok but named no workspace" — two
# different warnings, and collapsing them would hide a broken surface.
# --cwd must be the repository root: the backend refuses to open a linked
# checkout's own workspace. --no-focus so the pipeline never steals focus.
_view_open() { # <path> <label>
  local out rc=0
  out=$(herdr worktree open --cwd "$(_view_repo_root)" --path "$1" \
    --label "$2" --no-focus --json 2>/dev/null | head -n1) || rc=$?
  [[ $rc -eq 0 ]] || return "$rc"
  printf '%s' "$out" \
    | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null | head -n1
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
# This is where a pane that must outlive the working environment goes.
_view_home_workspace() {
  herdr worktree list --cwd "$(_view_repo_root)" --json 2>/dev/null \
    | jq -r '.result.source.source_workspace_id // empty' 2>/dev/null | head -n1
}

# Tab of WORKSPACE the caller should land in: the focused one when there is one,
# otherwise the first (the tab the backend opened for that checkout). Empty
# when it cannot be resolved, which sends the caller down the new-tab fallback.
_view_workspace_tab() {
  local ws=$1
  herdr tab list --workspace "$ws" 2>/dev/null \
    | jq -r '([.result.tabs[]? | select(.focused == true)] + [.result.tabs[]?])
             | (.[0].tab_id // empty)' 2>/dev/null | head -n1
}

# Keep the repo-home workspace alive across the attach. This is not cosmetic:
# herdr CLOSES a workspace once its last pane leaves, and when the home goes,
# `source_workspace_id` stops resolving. Every nested workspace then renders
# FLAT — siblings, not nested under the repo's home — and, worse, `close` fails
# with view_close_unsafe_caller because _view_detach_caller has nowhere to land.
# The trigger is usually this very function: the caller sat alone in the home
# (that is what "starting from a workspace on main" looks like), so attaching it
# to the new working environment empties the home. One plain shell pane, split next to the
# caller while it is still there, is enough to hold the link. Splitting a PANE
# rather than creating a workspace is deliberate: `pane split` has no
# --workspace (only [PANE_ID]/--pane/--current), and the caller is in the home
# by definition here. No-op when the caller is not in the home, and when the
# split cannot be created — a failed pin must not abort the attach.
_view_pin_home() { # <caller workspace> <caller pane>
  local ws=$1 pane=$2 home
  [[ -n $ws && -n $pane ]] || return 0
  home=$(_view_home_workspace || true)
  [[ -n $home && $home == "$ws" ]] || return 0
  herdr pane split --pane "$pane" --direction down \
    --cwd "$(_view_repo_root)" --no-focus >/dev/null 2>&1 || true
}

# Move the CALLER's pane into TARGET. The run happens in that pane, so a view
# nobody is inside is a lie: the session belongs where the work is. No-op when
# the caller is not in a herdr pane or is already there.
#
# It lands in the workspace's EXISTING tab, as a split: `herdr pane move` only
# accepts --workspace together with --new-tab, so joining the workspace means
# --tab + --split (verified against the CLI's own usage). A second tab would
# separate the run from that checkout's own terminal for nothing. When the tab
# cannot be resolved, --new-tab is still better than not moving at all: a run
# outside the view is exactly the lie this function exists to prevent.
_view_attach_caller() {
  local target=$1
  [[ -n $target ]] || return 0
  local info cur pane
  info=$(_view_caller || true)
  [[ -n $info ]] || return 0
  cur=${info#*$'\t'} pane=${info%%$'\t'*}
  [[ -n $pane && -n $cur && $cur != "$target" ]] || return 0
  _view_pin_home "$cur" "$pane"
  local tab
  tab=$(_view_workspace_tab "$target")
  if [[ -n $tab ]]; then
    herdr pane move "$pane" --tab "$tab" --split right --no-focus \
      >/dev/null 2>&1
  else
    herdr pane move "$pane" --new-tab --workspace "$target" --no-focus \
      >/dev/null 2>&1
  fi
}

# Drop the terminal that workspace was born with. The backend can only create a
# workspace TOGETHER WITH a pane — no herdr flag suppresses it
# (`workspace create` takes only --cwd/--label/--env/--focus/--no-focus) — so the
# placeholder cannot be avoided, only collected. Once _view_attach_caller has
# moved the caller in, that pane is the one nobody asked for: the caller is the
# run, the tool panes anchor to the caller, and nothing ever drives the
# placeholder. Left alone it sits there for the whole run as a dead shell.
#
# The invariant that makes reaping safe: herdr CLOSES a workspace when its last
# pane leaves (the reason _view_pin_home exists). So the placeholder is reaped
# only while the workspace still holds another pane, and never the caller's own
# pane. A run whose caller is not in a herdr pane keeps its shell, where the
# placeholder is not redundant but the only way into the working environment.
#
# Ids are read live and used at once: the layout renumbers them on every change,
# so a cached id is a dead id (same trap HERDR_PANE_ID falls into).
_view_reap_placeholder() { # <workspace> <workingEnvironment>
  local ws=$1 wt=$2
  [[ -n $ws && -n $wt ]] || return 0
  local -a rows=()
  local row p cwd info caller
  while IFS=$'\t' read -r p cwd; do
    [[ -n $p ]] && rows+=("$p"$'\t'"$cwd")
  done < <(herdr pane list --workspace "$ws" 2>/dev/null \
           | jq -r '.result.panes[]? | [.pane_id, .cwd] | @tsv' 2>/dev/null)
  ((${#rows[@]} > 1)) || return 0
  info=$(_view_caller || true)
  caller=${info%%$'\t'*}
  for row in "${rows[@]}"; do
    p=${row%%$'\t'*} cwd=${row#*$'\t'}
    [[ -n $caller && $p == "$caller" ]] && continue
    [[ $cwd == "$wt" ]] || continue
    # Only a pane idling at a prompt: anything the user or a tool started there
    # is theirs, and closing it would take their work down with the placeholder.
    _view_pane_is_shell "$p" || continue
    herdr pane close "$p" >/dev/null 2>&1 || true
    return 0
  done
  return 0
}

# Move the CALLER's pane OUT of FROM before FROM is torn down. Closing a
# workspace closes its panes, and the caller's pane is the session running the
# pipeline itself: it has to survive the working environment. Returns non-zero when the
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

# Open an editor on the working environment as a right-hand pane, ONCE. Idempotent by
# inspection, not by state: if any pane in the workspace already runs the
# editor, the layout is the user's and is left alone. Runs after the attach, so
# --current is the caller's pane now sitting inside that workspace.
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
# True when PANE's foreground process is a plain shell. The name list is the one
# place that decides "this pane is just sitting at a prompt", shared by the wait
# below and the placeholder reap, which must agree on what a bare pane is.
_view_pane_is_shell() { # <pane>
  local name
  name=$(herdr pane process-info --pane "$1" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[0].name // empty' \
    2>/dev/null) || return 1
  case $name in fish|bash|zsh|sh|dash|ksh|nu|xonsh) return 0 ;; esac
  return 1
}

_view_pane_wait_shell() { # <pane>
  local pane=$1 i
  for ((i = 0; i < 24; i++)); do
    _view_pane_is_shell "$pane" && return 0
    sleep 0.25
  done
  return 1
}

# Open a tool pane on the working environment, ONCE. Sets VIEW_NEW_PANE to the pane it
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
      # VIEW_NEW_PANE is read by workspace.sh after _view_open_tool returns, so
      # it looks unused from inside this file.
      # shellcheck disable=SC2034
      VIEW_NEW_PANE=$new
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# --- close ------------------------------------------------------------------

# Detaches the visual surface. Idempotent by design: the goal state is "no view
# on this working environment", so an id that is already gone, or an empty id, is success.
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
