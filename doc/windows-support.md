# Windows / PowerShell Native Support — Reference

This document records the details of adding native Windows
(`cmd`/`PowerShell`) support to `agent-git-setup`. It exists so
future sessions can recall the design decisions, test parity, and
known differences without re-deriving them.

## What was built

Three new files, plus documentation and CI updates:

| File | Purpose |
|------|---------|
| `scripts/agent-git-setup.ps1` | PowerShell port of `scripts/agent-git-setup.sh`. Identity-only: writes `user.name`/`user.email` to `.git/agent-bot-identity.config` and adds an `includeIf.gitdir/i:**/.git/worktrees/**.path` entry to the shared `.git/config`. Same Guard A/B/C, same `--preflight` fail-closed behavior, same effect-based worktree verification. |
| `tests/agent-git-setup-test.ps1` | Hermetic PowerShell test suite mirroring `tests/agent-git-setup-test.sh`. Same 19 test cases. Uses `$env:` for env vars, `Join-Path` instead of path concatenation, `MakeFakeGh` factory instead of bash heredoc `gh` mock, `Register-ObjectEvent` for cleanup. |
| `skills/agent-git-setup/scripts/agent-git-setup.ps1` | Bundled copy synced by `make sync-skill-scripts`. |

## Design decisions

- **Identity-only, no worktree management.** The PowerShell port does NOT create worktrees, does NOT install hooks, does NOT rewrite remotes, and does NOT impose a path or branch convention. This matches the bash script exactly — worktree lifecycle is the harness's responsibility.
- **No SSH signing by default.** Same as the bash script: local commits use the bot noreply email only. The "verified" badge is not worth the key-management complexity for ephemeral agent environments.
- **Same env vars.** `AGENT_GIT_NAME`, `GIT_USER_NAME`, `GH_TOKEN`, `AGENT_GIT_BOT_ID`, `AGENT_GIT_ALLOW_HUMAN_ACTOR`, `AGENT_GIT_ALLOW_TMP` all work identically.
- **`includeIf` conditional-include.** The bot config is written ONCE to the shared `.git/config` and applies to every linked worktree (including those created after setup). The main repo's own `.git` directory is excluded by the glob.
- **`--preflight` ported.** Fails closed in the main repo (bot identity not in effect) and when `GH_TOKEN` is missing. Verifies the `gh` actor via `gh api user`. Uses a fake `gh` on `PATH` in tests to avoid calling the real `gh`.

## Test parity

The PowerShell test suite (`tests/agent-git-setup-test.ps1`) mirrors
`tests/agent-git-setup-test.sh` case-for-case:

1. Happy path: one-off setup scopes all worktrees, main untouched
2. Idempotent re-run
3. Future worktree (created AFTER setup) auto-inherits bot
4. Commit in worktree is authored as bot
5. Missing required env: errors
6. Invalid `GIT_USER_NAME` rejected before network
7. Not-a-git-dir argument: errors
8. Noreply email construction (`GIT_USER_ID` + `GIT_USER_NAME`)
9. Noreply from bot id via `AGENT_GIT_BOT_ID` (no network needed)
9b. Last-resort account-owner fallback when bot id cannot be resolved
10. No signing by default
11. No hooks / no `core.hooksPath` written
12. Ephemeral-location guard: refuses without opt-in
13. Self-nesting guard: refuses when script lives inside target repo
14. Works when given a linked worktree path
15. True failure only when NOTHING resolves
16. `--preflight` refuses the main repo (bot identity not in effect)
17. `--preflight` requires `GH_TOKEN`; passes when bot identity resolves
18. `--preflight` fails in a separate clone (effect-based, not path-based)
19. `--preflight` verifies the `GH_TOKEN` actor is the BOT

Test results on the Linux box (where `pwsh` is absent, the
PowerShell suite is skipped with a message):
- `bash tests/agent-git-setup-test.sh` — PASS=*** FAIL=0
- `bash tests/mint-token-test.sh` — PASS=*** FAIL=0
- `make ci` — clean

## CI integration

`.github/workflows/ci.yml` was updated to add a `test-windows` job
on `windows-latest` that runs `pwsh tests/agent-git-setup-test.ps1`.
The original single `test` job was split into `test-linux` and
`test-windows`. The `lint` job now includes a `PSScriptAnalyzer`
step for `*.ps1` files (also installed via `make install`).

## Known differences from the bash script

- **`$env:` syntax** instead of `export`. PowerShell environment
  variables are set via `$env:VARNAME = "value"`.
- **`Join-Path`** instead of path concatenation with `/`.
- **`Register-ObjectEvent`** for cleanup instead of `trap`.
- **`pwsh`** must be installed (PowerShell 7+ Core). The `make
  install` target handles this on macOS (`brew install --cask
  powershell`) and Linux (`apt-get install powershell`).
- **`PSScriptAnalyzer`** is used instead of `shellcheck`/`shfmt`
  for the `.ps1` files. The `lint` target skips it gracefully
  when `pwsh` is absent.

## Lessons / pitfalls for future sessions

- **Makefiles need space-delimited pairs, not pipe-delimited.** The original `sync-skill-scripts` / `sync-check` used `|` as a delimiter between source and destination in `for` loop pairs; Make's `set --` splits on whitespace, so the `|` got eaten. Switched to space-delimited pairs (`src dst`).
- **`pwsh` may be absent locally.** The `test` and `lint` Makefile targets check `command -v pwsh` and skip gracefully when it's missing. CI always has it.
- **Bundled copy must be synced.** `make sync-skill-scripts` copies `scripts/*.ps1` into `skills/agent-git-setup/scripts/`. `make ci` runs `sync-check` first and refuses to test a drifted bundle.
- **Skill `platforms` field must be updated.** The SKILL.md YAML frontmatter `platforms` field was `[linux, macos]`; updated to `[linux, macos, windows]`.
