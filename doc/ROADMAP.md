# Roadmap

Loose plan for agent-git-setup. Nothing here is committed to a release; it is
a working list so contributors (human or agent) know what is considered.

## Windows / PowerShell native support (planned, CI-verified)

The script currently targets bash on Linux/macOS. Native Windows
(`cmd`/`PowerShell`) is not supported, though WSL and Git Bash work.

Plan:
- Add `agent-git-setup.ps1` — a PowerShell port of the same logic (git worktree
  add, write the worktree's own config file, idempotent, no origin rewrite,
  optional signing). Scope is commit-author isolation only: like the bash
  script, it does NOT make `git push` the bot — only the commit author and
  gh/API actor via `GH_TOKEN`.
- Add `agent-git-setup-test.ps1` — hermetic tests (temp repo, sandboxed
  `$env:HOME` / `$env:GIT_CONFIG_GLOBAL`, dummy token, no network, cleanup in
  `finally`).
- Extend `.github/workflows/test.yml` with a `windows` job on
  `windows-latest` that runs the `.ps1` tests. The Windows runner is the
  verification loop (the Linux box cannot run PowerShell).

Caveats: the `.ps1` would be written without a local Windows shell, so expect a
few CI round-trips before green. Two implementations must be kept in sync on
every behaviour change (drift cost).

## Verify treehouse integration (planned)

The script detects `treehouse` and uses it for the worktree, else falls back to
`git worktree add`. The treehouse path is currently unexercised. Add a test
(or CI step with treehouse installed) that confirms the treehouse branch works.

## Test framework (no change planned)

Current `agent-git-setup-test.sh` is a zero-dependency hermetic suite. `bats`
is the more formal option but adds a dependency. Keep the simple approach
unless tests grow.
