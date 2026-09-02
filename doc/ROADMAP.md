# Roadmap

Loose plan for agent-git-setup. Nothing here is committed to a release; it is
a working list so contributors (human or agent) know what is considered.

## Windows / PowerShell native support (done)

`scripts/agent-git-setup.ps1` provides native Windows support
(`cmd`/`PowerShell`), mirroring the bash script's identity-only
semantics (commit-author isolation via `includeIf`, no origin rewrite,
no hooks, no worktree management). The hermetic test suite now runs
on both platforms: `tests/agent-git-setup-test.sh` (Linux/macOS) and
`tests/agent-git-setup-test.ps1` (Windows). CI runs both jobs in
`.github/workflows/ci.yml`.

## Verify treehouse integration (planned)

The script detects `treehouse` and uses it for the worktree, else falls back to
`git worktree add`. The treehouse path is currently unexercised. Add a test
(or CI step with treehouse installed) that confirms the treehouse branch works.

## Test framework (no change planned)

Current `agent-git-setup-test.sh` is a zero-dependency hermetic suite. `bats`
is the more formal option but adds a dependency. Keep the simple approach
unless tests grow.