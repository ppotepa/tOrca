# Branch consolidation ledger — 2026-08-06

This record documents the consolidation of the long-lived Torca branches into `main`.

## Consolidated histories

- `agent/refactor-0.3-completion` — merged through PR #10 at `0cc9d314f0ba19d5a2dfbf676ccd2a1263c5f1d8`.
- `refactor/0.3-finalize-architecture` — head `ea22ab7e60fef28f2750f01ddfe4effeed577f79`.
- `refactor/0.3.10-direct-lookups` — head `e1ce127c8d16c4e9b00554cb9d7664612d211658`.
- `agent/ephemeral-relay-cleanup` — head `59dc8ce63ac5208fbfd7da41fbb1b6443a42a676`.

The duplicate `refactor/0.3.10-final*`, `refactor/0.3.10-integration` and `refactor/0.3.10-work*` heads are ancestors of `refactor/0.3.10-direct-lookups` and are therefore included transitively.

## Conflict policy

1. The current `main` implementation wins for files changed by PR #10 and for obsolete deletions from older branches.
2. Branch-only contracts, ABI files, platform ports, generated metadata, SQL files, documentation and architecture tools are retained in the resulting tree.
3. Parallel actor/runtime source files are retained under their original paths but are not wired over the newer command pipeline when their module wiring conflicted with PR #10.
4. No branch snapshot is allowed to replace or rewind the current `main` tree.

## Validation status

The repository GitHub Actions runner currently terminates jobs before assigning a runner (`steps: []`, `runner_id: 0`). The consolidation records history and conflict resolution, but does not claim a successful compile or test run.
