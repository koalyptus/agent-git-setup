# Repository Agent Guide

## Scope

- This file guides changes to this repository. For end-user setup instructions, read `README.md` and `skills/agent-git-setup/SKILL.md`.
- Keep Bash and PowerShell behavior aligned. Update tests and both user-facing guides when the contract changes.
- `AGENT_GIT_BOT_ID` is an internal override; normal setup resolves bot identity automatically. Do not ask users to supply it in prompts or document it as a prerequisite.
- Push identity comes from Git's configured credential mechanism. The setup scripts configure commit identity only; do not claim that they force pushes to use either the human or bot credential.

## Source of Truth

- Root scripts in `scripts/` are canonical.
- After changing a root script, run `make sync-skill-scripts` to update `skills/agent-git-setup/scripts/`. Do not edit bundled copies independently.
- Run `make sync-check` to verify the bundle is synchronized.

## Validation

- Run `make test` for the Bash, PowerShell (when available), and token-minter suites. Run `pwsh tests/agent-git-setup-test.ps1` directly when PowerShell is available but not visible to Make's shell.
- Run `make lint` for ShellCheck, shfmt, and PSScriptAnalyzer checks.
- Run `make ci` before proposing a change when the local toolchain supports all targets.
- Keep tests hermetic: use synthetic credentials and local fixtures; never use a real App key or token.