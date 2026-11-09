#!/usr/bin/env bash
# contract.sh — proof that the `swe` facade is a drop-in replacement for
# the original monolith.
#
# Two layers:
#   A. Differential: run the frozen baseline monolith and the new facade on the
#      same invocation matrix, from the same cwd, and require stdout (volatile
#      absolute paths normalized to <TMP>) and exit code to be indistinguishable.
#      This is self-calibrating: it makes no claim about what the environment
#      SHOULD do, only that both binaries agree on what it does.
#   B. Invariants: the facade's own hard rules — stdout purity (one line of
#      JSON, or none for usage), parseable JSON with an "ok" boolean, a warnings
#      key on every failure, manifest integrity, and the location contract.
#
# The matrix runs from a fresh non-git temp directory on purpose: the git-backed
# branches then resolve deterministically in both binaries. Successful `ensure`
# cases are excluded — they create worktrees and are not environment-independent.
#
# Run with: bash tests/contract.sh   (exits non-zero if any case fails)

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(dirname "$HERE")
ENTRY="$ROOT/swe.sh"
BASE="$HERE/baseline/swe-workspace-manager.sh"
MANIFEST="$ROOT/lib/verbs.manifest"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
check() { # check <label> <expected> <actual>
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
RUN=$(mktemp -d "$tmp/run.XXXXXX")

# Any path under the temp root is machine-specific; both binaries must produce
# the same bytes once it is replaced.
#
# Plus the one intended divergence from the frozen baseline: the JSON contract was
# renamed from `worktree` to `workingEnvironment` and `not_a_git_work_tree` to
# `not_a_git_repository`, so the contract names the run rather than the mechanism.
# The mapping is applied to BOTH sides, which is idempotent: the facade's output
# no longer contains the old strings, and the baseline's must be read as what it
# now means. The baseline stays frozen — regenerating it from the facade would
# make this differential compare the new implementation against a copy of itself.
#
# The frozen baseline also predates the run's VCS/forge facets: `location` now
# answers `git` and `forge` so a caller never has to guess from a failed ensure.
# They are additive — their own invariants live in section B — and the baseline
# can never carry them. So the differential compares the shared subset, dropping
# those two keys from BOTH sides. Dropping them from both keeps the check honest:
# a facade that stopped answering them still diffs here.
norm() {
  sed -e "s#$tmp#<TMP>#g" \
      -e 's/no_worktree_for_branch/no_working_environment_for_branch/g' \
      -e 's/session_inside_worktree/session_inside_working_environment/g' \
      -e 's/worktree_not_found/working_environment_not_found/g' \
      -e 's/dirty_worktree/dirty_working_environment/g' \
      -e 's/already_in_linked_worktree/already_in_working_environment/g' \
      -e 's/not_a_git_work_tree/not_a_git_repository/g' \
      -e 's/current_worktree/current_workingEnvironment/g' \
      -e 's/"worktree":/"workingEnvironment":/g' \
      -e 's/,"git":[a-z]*,"forge":[a-z]*//g'
}

# Run a binary from RUN with a clean git environment, capturing streams.
run_bin() { # run_bin <bin> <out> <err> [args...]
  local bin=$1 out=$2 err=$3
  shift 3
  ( cd "$RUN" && unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR && bash "$bin" "$@" ) >"$out" 2>"$err"
}

# One matrix case: differential + exit code + stdout purity + JSON shape.
case_run() { # case_run <label> <expect_exit> <expect_reason|-> [args...]
  local label=$1 exp_exit=$2 exp_reason=$3
  shift 3

  local be ne bo no
  run_bin "$BASE" "$tmp/base.out" "$tmp/base.err" "$@"; be=$?
  run_bin "$ENTRY" "$tmp/new.out" "$tmp/new.err" "$@"; ne=$?
  bo=$(norm <"$tmp/base.out")
  no=$(norm <"$tmp/new.out")

  if [[ $be -eq $ne && $bo == "$no" ]]; then
    ok "diff $label"
  else
    bad "diff $label (exit $be/$ne)"
    printf '      base=[%s]\n      new =[%s]\n' "$bo" "$no"
  fi

  check "exit $label" "$exp_exit" "$ne"

  local -a lines
  mapfile -t lines <"$tmp/new.out"
  local exp_lines=1
  [[ $exp_exit -eq 2 ]] && exp_lines=0
  check "stdout-lines $label" "$exp_lines" "${#lines[@]}"

  if [[ -n $no ]]; then
    if printf '%s\n' "$no" | jq -e . >/dev/null 2>&1; then
      ok "jq $label"
    else
      bad "jq $label"
    fi
    check "has-ok $label" "true" "$(printf '%s\n' "$no" | jq -r 'has("ok")')"
  fi

  if [[ $exp_exit -eq 1 ]]; then
    check "fail-warnings $label" "true" \
      "$(printf '%s\n' "$no" | jq -r 'has("warnings")')"
  fi

  if [[ $exp_reason != - ]]; then
    check "reason $label" "$exp_reason" \
      "$(printf '%s\n' "$no" | jq -r '.reason // "-"')"
  fi
}

echo "=== A. differential matrix (baseline vs swe) ==="
case_run "no args"            2 -
case_run "-h"                 2 - -h
case_run "--help"             2 - --help
case_run "help"               2 - help
case_run "bogus"              1 unknown_subcommand_bogus bogus
case_run "ensure"             1 missing_--type ensure
case_run "ensure no slug"     1 missing_--slug ensure --type feature
case_run "ensure bad type"    1 invalid_type_bogus ensure --type bogus --slug x
case_run "ensure bad slug"    1 "invalid_slug_Bad Slug" ensure --type feature --slug 'Bad Slug'
case_run "ensure unknown arg" 1 unknown_argument_--foo ensure --type feature --slug x --foo
case_run "resolve"            1 missing_--branch resolve
case_run "resolve nope"       1 not_a_git_repository resolve --branch nope
case_run "resolve bogus/x"    1 not_a_git_repository resolve --branch bogus/x
case_run "remove"             1 missing_--branch remove
case_run "close"              0 - close
case_run "location"           0 - location
case_run "location expect run" 0 - location --expect "$RUN"
case_run "location expect missing" 1 expect_not_a_directory location --expect /nonexistent-xyz

echo "=== B. explicit invariants ==="

# location with no args reports the session directory as pwd -P.
run_bin "$ENTRY" "$tmp/new.out" "$tmp/new.err" location
runreal=$(cd "$RUN" && pwd -P)
check "location session_dir == pwd -P" \
  "$(printf '%s' "$runreal" | norm)" \
  "$(printf '%s\n' "$(norm <"$tmp/new.out")" | jq -r '.session_dir')"

# location --expect <current dir> matches.
run_bin "$ENTRY" "$tmp/new.out" "$tmp/new.err" location --expect "$RUN"
check "location --expect current -> match" "true" "$(jq -r '.match' <"$tmp/new.out")"

# location --expect <missing dir> is a hard failure.
run_bin "$ENTRY" "$tmp/new.out" "$tmp/new.err" location --expect /nonexistent-xyz
ne=$?
check "location --expect missing -> exit" 1 "$ne"
check "location --expect missing -> reason" "expect_not_a_directory" \
  "$(jq -r '.reason' <"$tmp/new.out")"
check "location --expect missing -> warnings" "true" \
  "$(jq -r 'has("warnings")' <"$tmp/new.out")"

# open-issue is a PIPELINE verb: a usage error is exit 2 and prints no JSON at
# all. It is not part of the differential matrix because the frozen baseline
# never had it — the invariant is what matters, not the agreement.
run_bin "$ENTRY" "$tmp/new.out" "$tmp/new.err" open-issue
ne=$?
check "open-issue usage exit" 2 "$ne"
check "open-issue usage stdout" 0 "$(wc -l <"$tmp/new.out" | tr -d ' ')"

# Idempotency through the injected mechanism: the second call must answer with
# the item the first one published and reach NO mechanism. The injected
# implementation fails loudly if it is called twice, so a duplicate publication
# cannot pass as a success.
oifile="$tmp/oi/issue.md"
mkdir -p "$tmp/oi"
printf '# Tracked work\n\nBody.\n' > "$oifile"
cat > "$tmp/issue-mechanism.sh" <<'EOS'
mechanism_open_issue() { # <title> <body-file>
  if [[ -f ${OI_CALLED:?} ]]; then
    printf '{"error":"called_twice"}\n'
    return 1
  fi
  : >"$OI_CALLED"
  printf '{"ok":true,"forge":"github","number":5,"url":"https://example.invalid/o/r/issues/5"}\n'
}
EOS
oi_run() { # oi_run <out>
  ( cd "$RUN" && SWE_CHANGE_MECHANISM="$tmp/issue-mechanism.sh" OI_CALLED="$tmp/oi/called" \
      bash "$ENTRY" open-issue --issue-file "$oifile" ) >"$1" 2>"$tmp/new.err"
}
oi_run "$tmp/new.out"
check "open-issue first ok" true "$(jq -r '.ok' <"$tmp/new.out")"
check "open-issue first number" 5 "$(jq -r '.issue.number' <"$tmp/new.out")"
check "open-issue first existing" false "$(jq -r '.existing' <"$tmp/new.out")"
oi_run "$tmp/new.out"
check "open-issue resume ok" true "$(jq -r '.ok' <"$tmp/new.out")"
check "open-issue resume existing" true "$(jq -r '.existing' <"$tmp/new.out")"
check "open-issue resume number" 5 "$(jq -r '.issue.number' <"$tmp/new.out")"
check "open-issue resume marker count" 1 "$(grep -c '^Forge-Issue:' "$oifile" || true)"

# Manifest integrity: every row points at a real file AND a function that exists
# after the module is sourced, and the verb set equals the handled subcommands.
mverbs=$(awk -F'\t' 'NF && $1 !~ /^#/ {print $1}' "$MANIFEST")
check "manifest verb set" $'ensure\nlocation\nresolve\nremove\nclose' "$mverbs"

fn_exists() { # fn_exists <module-file> <function>
  ( SWE_LIB="$ROOT/lib"
    # shellcheck source=/dev/null
    . "$SWE_LIB/core.sh"
    _SWE_SOURCED=(core.sh)
    # shellcheck source=/dev/null
    . "$SWE_LIB/$1"
    declare -F "$2" >/dev/null 2>&1 )
}

while IFS=$'\t' read -r verb module fn; do
  [[ -n $verb && $verb != \#* ]] || continue
  if [[ -f "$ROOT/lib/$module" ]]; then
    ok "manifest file: $verb -> $module"
  else
    bad "manifest file: $verb -> $module (missing)"
  fi
  if fn_exists "$module" "$fn"; then
    ok "manifest fn:   $verb -> $fn"
  else
    bad "manifest fn:   $verb -> $fn (undefined after sourcing $module)"
  fi
  # The entrypoint must dispatch this verb, not reject it as unknown.
  run_bin "$ENTRY" "$tmp/new.out" "$tmp/new.err" "$verb" --zz-unknown-flag
  check "dispatch:     $verb" "unknown_argument_--zz-unknown-flag" \
    "$(jq -r '.reason // "-"' <"$tmp/new.out")"
done <"$MANIFEST"

echo
printf '%d/%d passed\n' "$pass" "$((pass + fail))"
[[ $fail -eq 0 ]]
