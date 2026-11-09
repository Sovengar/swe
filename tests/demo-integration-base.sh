#!/usr/bin/env bash
# demo-integration-base.sh — show repo-native integration-base resolution on
# real repositories, not fixtures. Read-only: it creates one scratch repository
# under TMPDIR and removes it on exit. Run from anywhere inside a checkout:
#
#   bash home/dot_local/lib/swe/tests/demo-integration-base.sh
#
# It answers the question the bug was about: which base does swe compute for a
# repository whose default branch is not `dev`?

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(dirname "$HERE")

# Resolve one repository by sourcing the same mechanism the verbs use.
resolve() { # <dir>
  (
    cd "$1" || exit 1
    SWE_LIB="$ROOT/lib" SWE_INTEGRATION_BASE="${SWE_INTEGRATION_BASE:-}" bash -c '
      set -euo pipefail
      . "$SWE_LIB/core.sh"; _SWE_SOURCED=(core.sh)
      . "$SWE_LIB/change/mechanism.sh"
      if out=$(mechanism_destination 2>/dev/null); then
        printf "  integration_base: %s\n  source:           %s\n" \
          "$(printf "%s" "$out" | jq -r .integration_base)" \
          "$(printf "%s" "$out" | jq -r .base_source)"
      else
        printf "  integration_base: UNRESOLVED\n  error:            %s\n" \
          "$(printf "%s" "$out" | jq -r .error)"
        exit 1
      fi'
  )
}

echo "== this repository =="
printf '  path: %s\n' "$(git rev-parse --show-toplevel)"
resolve "$(git rev-parse --show-toplevel)"
echo

echo "== scratch repository whose default branch is main =="
scratch=$(mktemp -d "${TMPDIR:-/tmp}/swe-base-demo.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
(
  cd "$scratch" || exit 1
  git init -q -b main .
  git config user.email demo@example.invalid
  git config user.name swe-demo
  git commit -q --allow-empty -m 'chore: base'
  git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git checkout -q -b feat/demo
  git commit -q --allow-empty -m 'feat: work'
  git remote add origin "https://example.invalid/demo.git"
)
printf '  path: %s\n' "$scratch"
resolve "$scratch"
echo

echo "== the same scratch repository, pinned by the escape hatch =="
printf '  path: %s\n' "$scratch"
SWE_INTEGRATION_BASE=release resolve "$scratch"
echo

echo "== a repository with no resolvable base (must fail, never fold its history) =="
bare=$(mktemp -d "${TMPDIR:-/tmp}/swe-base-none.XXXXXX")
trap 'rm -rf "$scratch" "$bare"' EXIT
(
  cd "$bare" || exit 1
  git init -q -b main .
  git config user.email demo@example.invalid
  git config user.name swe-demo
  git commit -q --allow-empty -m 'chore: base'
  git checkout -q -b feat/demo
  git commit -q --allow-empty -m 'feat: work'
)
printf '  path: %s\n' "$bare"
resolve "$bare" || true
