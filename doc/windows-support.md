# Windows / PowerShell Native Support — Reference

This document records the details of adding native Windows
(`cmd`/`PowerShell`) support to `agent-git-setup`. It exists so
future sessions can recall the design decisions, test parity, and
known differences without re-deriving them.

## What was built

Three new files, plus documentation and CI updates:

| File | Purpose |
|------|---------|
| `scripts/agent-git-setup.ps1` | PowerShell port of `scripts/agent-git-setup.sh`. Identity-only: writes `user.name`/`user.email` to `.git/agent-bot-identity.config` and adds an `includeIf.gitdir/i:**/.git/worktrees/**.path` entry to the shared `.git/config`. Validates effective author and committer identity in GitHub's bot noreply format. |
| `tests/agent-git-setup-test.ps1` | Hermetic PowerShell suite using real temporary Git repos/worktrees, synthetic identities, a global fake `gh` function, a throwing `Invoke-RestMethod` stub, isolated Git/GH config, and cleanup. |
| `skills/agent-git-setup/scripts/agent-git-setup.ps1` | Bundled copy synced by `make sync-skill-scripts`. |

## Design decisions

- **Identity-only, no worktree management.** The PowerShell port does NOT create worktrees, does NOT install hooks, does NOT rewrite remotes, and does NOT impose a path or branch convention. This matches the bash script exactly — worktree lifecycle is the harness's responsibility.
- **No SSH signing by default.** Same as the bash script: local commits use the bot noreply email only. The "verified" badge is not worth the key-management complexity for ephemeral agent environments.
- **Bot-only commit identity.** `AGENT_GIT_NAME` and the numeric `AGENT_GIT_BOT_ID` determine the bot's noreply identity. There is no human-email fallback; setup fails if the bot ID cannot be resolved.
- **Mode-specific preflight.** `git-only` needs no token. `github` requires `GH_TOKEN` and a signed attestation containing App ID, actor, token hash, attestation signature, and PEM path. It verifies the signature/token binding, actor match, and `gh repo view` access to the current repo.
- **`includeIf` conditional-include.** The bot config is written ONCE to the shared `.git/config` and applies to every linked worktree (including those created after setup). The main repo's own `.git` directory is excluded by the glob.
- **`--preflight` ported.** Both modes require a linked worktree and verify effective author/committer identity. GitHub mode verifies an App-key signature binding actor metadata to the exact token, then checks current-repo access. Tests mock `gh` and network lookups.

## Test parity

The PowerShell test suite (`tests/agent-git-setup-test.ps1`) covers the same
behavioral contract as `tests/agent-git-setup-test.sh`:

1. Happy path: one-off setup scopes all worktrees, main untouched
2. Idempotent re-run
3. Future worktree (created AFTER setup) auto-inherits bot
4. Commit in worktree is authored as bot
5. Missing required env: errors
6. Deprecated `GIT_USER_NAME` ignored
7. Not-a-git-dir argument: errors
8. Noreply email construction (`GIT_USER_ID` + `GIT_USER_NAME`)
9. Noreply from bot id via `AGENT_GIT_BOT_ID` (no network needed)
9a. Invalid and zero bot IDs rejected
9b. Human-email fallback refused when bot id cannot be resolved
10. No signing by default
11. No hooks / no `core.hooksPath` written
12. Ephemeral-location guard: refuses without opt-in
13. Self-nesting guard: refuses when script lives inside target repo
14. Works when given a linked worktree path
15. True failure only when NOTHING resolves
16. Git-only preflight requires a linked worktree and validates author/committer overrides without a token
17. GitHub preflight verifies actor, token fingerprint, and repository access
18. `--preflight` fails in a separate clone (effect-based, not path-based)
19. GitHub preflight rejects human, mismatched, stale, and unverifiable actor metadata

The PowerShell suite runs in CI on `windows-latest` and can be run locally with
`pwsh tests/agent-git-setup-test.ps1`. Its GitHub CLI and network dependencies
are mocked; the Bash and token-minter suites remain offline and use synthetic
identities and keys.

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
- **`try/finally`** for cleanup instead of a Bash `trap`.
- **`pwsh`** must be installed (PowerShell 7+ Core). The `make
  install` target handles this on macOS (`brew install --cask
  powershell`) and Linux (`apt-get install powershell`).
- **`PSScriptAnalyzer`** is used instead of `shellcheck`/`shfmt`
  for the `.ps1` files. The `lint` target skips it gracefully
  when `pwsh` is absent.
- GitHub-mode PowerShell preflight requires `AGENT_GIT_TOKEN_ACTOR` and
  `AGENT_GIT_TOKEN_SHA256` from the token provider, then verifies repository
  access with `gh repo view`.

## Lessons / pitfalls for future sessions

- **Makefiles need space-delimited pairs, not pipe-delimited.** The original `sync-skill-scripts` / `sync-check` used `|` as a delimiter between source and destination in `for` loop pairs; Make's `set --` splits on whitespace, so the `|` got eaten. Switched to space-delimited pairs (`src dst`).
- **`pwsh` may be absent locally.** The `test` and `lint` Makefile targets check `command -v pwsh` and skip gracefully when it's missing. CI always has it.
- **Bundled copy must be synced.** `make sync-skill-scripts` copies `scripts/*.ps1` into `skills/agent-git-setup/scripts/`. `make ci` runs `sync-check` first and refuses to test a drifted bundle.
- **Skill `platforms` field must be updated.** The SKILL.md YAML frontmatter `platforms` field was `[linux, macos]`; updated to `[linux, macos, windows]`.
