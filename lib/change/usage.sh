#!/usr/bin/env bash
# usage.sh — the domain help for the PIPELINE entrypoint. It is a separate, pure
# module so every change/repository verb can show its own usage instead of the
# isolation one, without pulling the mechanism seam into a pure verb such as
# how-to-test.

change_usage() {
  cat >&2 <<'EOF'
Usage:
  swe how-to-test
  swe mutation-scope [--base <ref>]
  swe await-verification [--watch] [--timeout <seconds>]
  swe change-status
  swe open-issue --issue-file <path> [--plan-file <path>]
                                [--title <title>] [--dry-run]
  swe publish-change          # shared: push the current branch
  swe propose-change [--open] [--issue <n>] [--issue-file <path>] # worktree — open the pull request
  swe record-review --tip <tip> --verdict <pass|fix>
                                [--severity-json <json>] [--lenses-open <csv>]
                                [--verification <state>]
  swe review-round
  swe ready-to-integrate
  swe shape-change-history plan
  swe shape-change-history apply --messages <file>
  swe integrate-change [--issue <n>] [--issue-file <path>]
  swe clean-up-after-integration --change <change>

  This entrypoint owns the PIPELINE axis only. It never creates a working
  environment: `ensure`, `location`, `resolve`, `remove` and `close` belong to
  the isolation verbs of `swe` and are rejected here.

  Two publication verbs, chosen by the isolation (never by the caller):
    publish-change  PUSH. The shared isolation works on the real branch, so the
                    branch is the destination: no pull request, no --open.
    propose-change  PULL REQUEST. The worktree isolation works on a change
                    branch, so the change is proposed into the integration base.

  Both refuse a publication that would carry nothing:
    NO_COMMITS_TO_PUBLISH  — nothing ahead of the upstream / integration base
    CHANGE_BRANCH_IS_BASE  — propose-change from the integration base itself

Contract:
  stdout: exactly one line of JSON, always with an "ok" boolean. Nothing else.
  exit 0: ok=true.  exit 1: ok=false (reason inside the JSON).  exit 2: usage error.
  Progress and tool chatter go to stderr, so a caller can read stdout unfiltered.
EOF
  exit 2
}
