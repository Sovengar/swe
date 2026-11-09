# swe

One entrypoint for agent workflow runs. `swe <verb>` answers two questions that
must never be answered by the same code path:

| Axis | Question | Owner |
| --- | --- | --- |
| isolation | where does the run happen? | `isolation.sh` |
| pipeline | what is the state of my change? | `swe-pipeline.sh` |

`swe.sh` is the facade: it reads `lib/verbs.manifest` and `lib/change.manifest`,
routes the verb to the file that owns it, and holds no logic of its own.

The split is not cosmetic. A verb belongs to the axis that can satisfy its
precondition. A `shared` run works in place, on whatever branch the session
already had, so it has no change branch to propose: `swe publish-change` pushes
that branch, `swe propose-change` refuses. When one file served both axes, a
shared run advertised `propose-change` because a forge existed, then tried to
open a pull request from the integration base into itself.

## Install

```sh
make install
```

That is the whole install: it puts a symlink at `~/.local/bin/swe` pointing at
`swe.sh` in this repo, so edits here are live and there is nothing to rebuild.
Use `swe` from `PATH` — you never need to `cd` into this directory, and no script
references the checkout path. `BINDIR` overrides the target directory.

The facade resolves its own directory after following the symlink, so
`isolation.sh`, `swe-pipeline.sh` and `lib/` are found next to it and do not need
to be on `PATH`.

## Verbs

```
swe ensure --type <feature|fix|refactor|chore|docs> --slug <slug>
                       [--environment <worktree|shared>] [--base <ref>]
swe location [--expect <dir>]
swe resolve --branch <branch> [--from-anywhere]
swe remove --branch <branch> [--working-environment <path>]
                       [--base <ref>] [--force] [--force-delete]
swe close --view <view_id>

swe how-to-test
swe mutation-scope [--base <ref>]
swe await-verification [--watch] [--timeout <seconds>]
swe change-status
swe open-issue --issue-file <path> [--plan-file <path>] [--title <title>] [--dry-run]
swe publish-change          # shared: push the current branch
swe propose-change [--open] # worktree: open the pull request
swe record-review --tip <tip> --verdict <pass|fix>
swe review-round
swe ready-to-integrate
swe shape-change-history plan
swe shape-change-history apply --messages <file>
swe integrate-change
swe clean-up-after-integration --change <change>
```

## Contract

```
stdout: exactly one line of JSON, always with an "ok" boolean. Nothing else.
exit 0: ok=true.  exit 1: ok=false (reason inside the JSON).  exit 2: usage error.
```

Progress and tool chatter go to stderr, so a caller can read stdout unfiltered.

Publication is guarded at the only place that can prove it: a shared run refuses
`propose-change` (`CHANGE_BRANCH_IS_BASE`) and a branch with nothing over the
base refuses both verbs (`NO_COMMITS_TO_PUBLISH`). Both are refusals, not
warnings.

## Layout

| File | Role |
| --- | --- |
| `swe.sh` | facade: manifest routing, one exec |
| `isolation.sh` | lifecycle verbs; the only entrypoint that creates an environment |
| `swe-pipeline.sh` | change/repository verbs; assumes the environment exists |
| `lib/core.sh` | constants, JSON contract helpers, module loader, isolation usage |
| `lib/workspace.sh` | `ensure`, `remove` |
| `lib/session.sh` | `location`, `resolve` |
| `lib/view.sh` | `close` |
| `lib/git.sh` | the git seam: worktrees and branch removal |
| `lib/identity.sh` | harness detection |
| `lib/verbs.manifest` | verb → module → function, the isolation router |
| `lib/change.manifest` | verb → module → function, the pipeline router |
| `lib/change/mechanism.sh` | the mechanism seam (`git-forge`, `gitbutler`, ...) |
| `lib/change/*.sh` | one module per pipeline verb |

## Tests

```sh
make test    # behaviour suites, summarised by tests/run-all.sh
make lint    # shellcheck
make check   # parse only
```

The suites build throwaway repositories under a temporary `HOME` and need
`git` and `jq`; `lifecycle.sh` also needs `wt`, and reports `SKIP` without it.
`tests/baseline/swe-workspace-manager.sh` is the differential baseline the
contract suite compares against.

## Requirements

- `bash` 5
- `git`
- `jq`
- `wt` for `worktree` isolation
- `gh` for the forge mechanism
