# Windows / PowerShell Native Support — Reference

This document records native Windows (`cmd`/`PowerShell`) support for
`agent-git-setup`, including the GitHub App token minter used by
`agent-github-access`. It captures design decisions, test parity, and known
platform differences.

## What was built

Windows-specific scripts and hermetic tests, plus documentation and CI updates:

| File | Purpose |
|------|---------|
| `scripts/agent-git-setup.ps1` | PowerShell port of `scripts/agent-git-setup.sh`. Identity-only: writes `user.name`/`user.email` to `.git/agent-bot-identity.config` and adds an `includeIf.gitdir/i:**/.git/worktrees/**.path` entry to the shared `.git/config`. Validates effective author and committer identity in GitHub's bot noreply format. |
| `tests/agent-git-setup-test.ps1` | Hermetic PowerShell suite using real temporary Git repos/worktrees, synthetic identities, a global fake `gh` function, a throwing `Invoke-RestMethod` stub, isolated Git/GH config, and cleanup. |
| `scripts/mint-token.ps1` | Native PowerShell GitHub App token minter. Uses PowerShell/.NET RSA and web requests; no Bash or Python dependency. |
| `tests/agent-github-access-test.ps1` | Hermetic Windows access workflow test using a synthetic RSA key, mocked REST calls, fake `gh`, isolated config, and cleanup. |
| `skills/agent-github-access/scripts/mint-token.ps1` | Bundled PowerShell minter synced from `scripts/mint-token.ps1`. |
| `tests/agent-github-access-test.sh` | Hermetic Git Bash workflow test for the `agent-github-access` skill using a synthetic App key, mocked GitHub API, fake `gh`, isolated config, and cleanup. |
| `skills/agent-git-setup/scripts/agent-git-setup.ps1` | Bundled copy synced by `make sync-skill-scripts`. |

## Design decisions

- **Identity-only, no worktree management.** The PowerShell port does NOT create worktrees, does NOT install hooks, does NOT rewrite remotes, and does NOT impose a path or branch convention. This matches the bash script exactly — worktree lifecycle is the harness's responsibility.
- **No SSH signing by default.** Same as the bash script: local commits use the bot noreply email only. The "verified" badge is not worth the key-management complexity for ephemeral agent environments.
- **Bot-only setup scripts.** `AGENT_GIT_NAME` and the numeric `AGENT_GIT_BOT_ID` determine the bot's noreply identity. The scripts fail if the bot ID cannot be resolved. The `agent-git-setup` skill may offer a human-identity fallback only after explaining the resolved identity and receiving explicit approval.
- **Mode-specific preflight.** `git-only` needs no token. `github` requires `GH_TOKEN` and a signed attestation containing App ID, actor, token hash, signature, and PEM path. It verifies the signature/token binding, actor match, and `gh repo view` access. Native PowerShell uses Windows paths and does not require WSL. If `mint-token.sh` runs under WSL or Git Bash, it automatically exports an additional Windows-native PEM path via `wslpath` or `cygpath` when available.
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
9b. Setup script refuses human-email fallback when bot id cannot be resolved
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
are mocked. The Bash workflow test for `agent-github-access` runs in Linux CI
and can be run locally in Git Bash or WSL with `bash
tests/agent-github-access-test.sh`; it requires the actual `python3` command
and `cryptography`, the same prerequisites as the Bash token minter. GitHub
API and CLI calls use local fixtures, never live credentials or network access.
The PowerShell access test runs on Windows CI and can be run locally with
`pwsh tests/agent-github-access-test.ps1`; it requires only PowerShell 7+ and
Git, and does not contact GitHub.

## CI integration

`.github/workflows/ci.yml` has a `test-windows` job on `windows-latest` that
runs both `pwsh tests/agent-git-setup-test.ps1` and
`pwsh tests/agent-github-access-test.ps1`. The Bash GitHub access workflow
test runs in the Linux test job.
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
  access with `gh repo view`. `scripts/mint-token.ps1` produces these values
  natively using .NET cryptography.
- The `agent-github-access` skill uses `scripts/mint-token.ps1` on Windows,
  requiring PowerShell 7+ and GitHub connectivity. Linux/macOS use the Bash
  minter and require Python 3 with `cryptography`.

## Lessons / pitfalls for future sessions

- **Makefiles need space-delimited pairs, not pipe-delimited.** The original `sync-skill-scripts` / `sync-check` used `|` as a delimiter between source and destination in `for` loop pairs; Make's `set --` splits on whitespace, so the `|` got eaten. Switched to space-delimited pairs (`src dst`).
- **`pwsh` may be absent locally.** The `test` and `lint` Makefile targets check `command -v pwsh` and skip gracefully when it's missing. CI always has it.
- **Bundled copy must be synced.** `make sync-skill-scripts` copies `scripts/*.ps1` into `skills/agent-git-setup/scripts/`. `make ci` runs `sync-check` first and refuses to test a drifted bundle.
- **Skill `platforms` field must be updated.** The SKILL.md YAML frontmatter `platforms` field was `[linux, macos]`; updated to `[linux, macos, windows]`.
