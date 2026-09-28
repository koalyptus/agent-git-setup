---
name: agent-git-setup
description: "Set up a bot git identity (<name>[bot]) for an AI agent's worktree so commits are attributed to the bot, leaving the human's working tree untouched. Identity-only: the harness owns the worktree."
version: 2.0.0
author: koalyptus
license: MIT
platforms: [linux, macos, windows]
---

# Agent Git Setup

Give an AI agent its own bot identity so commits are attributed to `<name>[bot]`, not the human's account.

## When to use

- Agent does git work (commits, PRs) and should appear as `<name>[bot]`.
- Bot identity applies to every linked worktree in the clone; human's main checkout + global git config stay untouched.
- Triggers: "commit as a bot", "agent should commit as <bot>", "separate bot identity for the agent".

Do NOT use for a human's normal git login — that is personal PAT/SSH. This is for automation/bot attribution.

## Scope (read first)

- **Identity-only.** Does NOT create worktrees, install hooks, rewrite remotes, or impose path/branch conventions. Those are the **harness's** job.
- Harness places agent in a worktree; this skill configures one bot identity for all linked worktrees in that clone.
- Keeps harness's own worktree/hook/branch management untouched.

## What persists vs what doesn't

- **Commit author identity (step 4):** set ONCE per repo via `includeIf`. Persists. Every future worktree inherits it automatically. No per-session action.
- **GH_TOKEN (GitHub mode):** does NOT persist. Short-lived (~1h), env-only. Mint/export it for each session that performs GitHub operations as the bot.

## Happy path

1. **One-time: write credentials file.** Agent writes from `GITHUB_APP_ID` + `GITHUB_APP_PEM` (path) in the user's prompt. One file per App, under `credentials.d/` keyed by App ID.

   ```bash
   CRED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-git-setup"
   mkdir -p "$CRED_DIR/credentials.d"
   cat > "$CRED_DIR/credentials.d/credentials-${GITHUB_APP_ID}.env" <<EOF
   GITHUB_APP_ID=${GITHUB_APP_ID}
   GITHUB_APP_PEM=${GITHUB_APP_PEM}
   AGENT_GIT_BOT_ID=${AGENT_GIT_BOT_ID}
   EOF
   # User must chmod 600 this file + the PEM. Agent never sets permissions.
   ```

   `AGENT_GIT_BOT_ID` = numeric id of `<app-slug>[bot]` (the account GitHub created for the App). It is the email prefix that makes commits file under the **bot account**, not the human. Resolve via the unauthenticated public user API or set directly. If absent and online lookup fails, setup stops; it never substitutes the human identity. If you want the ID reused by the token minter, put it in this credentials file; setup does not write it there automatically.

   Credentials file holds: public App ID + PEM **path** + bot id. Never the PEM bytes or a live token.

   `mint-token.sh` resolves creds: explicit `--credentials`/`AGENT_GIT_CREDENTIALS` → `credentials.d/credentials-<APP_ID>.env` → global `credentials.env`. One bot per repo = first-class.

2. **Only for GitHub operations: mint + export GH_TOKEN.** Before any `gh`/API call. No env vars, no args needed when the credentials file is configured.

   ```bash
   source <(scripts/mint-token.sh --shell)
   # GH_TOKEN and AGENT_GIT_TOKEN_ACTOR exported in the agent's shell
   ```

   If `GITHUB_APP_ID`/`GITHUB_APP_PEM` already in env or passed as `--app-id`/`--pem`, those win.

   Minting does not happen for Git-only sessions. `--shell` derives the App slug from the App-JWT-authenticated `GET /app` response and exports `<app-slug>[bot]` as `AGENT_GIT_TOKEN_ACTOR` with `GH_TOKEN`. GitHub installation tokens do not expose their App slug to an introspection endpoint.

3. **Export bot identity vars.**

   ```bash
   export AGENT_GIT_NAME="myagent[bot]"   # replace with your bot's name (GitHub creates it as <app>[bot])
   ```

   `AGENT_GIT_NAME`: bot login, normally `<app-slug>[bot]`. Its numeric ID is looked up through the public user API without a token, or provide `AGENT_GIT_BOT_ID` directly for offline setup.

   `GIT_USER_NAME` is deprecated and not used to construct bot commit identity. Bot identity requires the bot's own numeric ID.

4. **Run setup once per repo.** Writes bot identity via `includeIf` into shared repo config. Every linked worktree (present + future) inherits the same bot identity. The main checkout stays human. The harness still chooses and creates the worktree.

   ```bash
   git clone --depth 1 https://github.com/koalyptus/agent-git-setup.git /tmp/agent-git-setup 2>/dev/null || true
   /tmp/agent-git-setup/scripts/agent-git-setup.sh .    # Linux/macOS
   /tmp/agent-git-setup/scripts/agent-git-setup.ps1 .   # Windows
   ```

   Does NOT create worktrees, branches, or touch main checkout. Prints isolation check. No `worktreeConfig` extension needed (`includeIf` works on git 2.43+).

5. **Run the matching preflight in the actual agent worktree, then work there.** Git-only sessions use `git-only`; sessions that call GitHub as the bot use `github`. Commits there = `<name>[bot]`; the main tree is untouched. A harness lifecycle hook is needed to guarantee preflight on every session.

   - Agent must NOT rewrite `origin` or set `remote.origin.url` (leaks bot push credential into main tree — worktrees share remotes).
   - Bot actor for `gh`/API (PRs, issues, comments) = `GH_TOKEN` in env, NOT rewritten origin.
   - Plain `git push` = human's credential (by design).
   - Agent must NOT touch main tree's `user.name`/`user.email` or global git config.

## Prerequisites

- Git repo the agent works in (git >= 2.43). Harness places agent in worktree; `includeIf` scopes to all worktrees, no `worktreeConfig` needed.
- `gh` (GitHub CLI) required for bot GitHub-actor path (PRs, comments, API commits). Local commits need only `git`.
- `python3` + `cryptography` if using `mint-token.sh` (GitHub App path). Not needed for Git-only commit author.
- GitHub App (App ID + PEM) only if using `mint-token.sh` for gh/API as bot. Not needed for Git-only.
- PowerShell 7+ for `agent-git-setup.ps1` (Windows). Same env vars as bash.

## Before work: mode-specific preflight

```bash
scripts/agent-git-setup.sh --preflight --mode git-only .  # local commits only
scripts/agent-git-setup.sh --preflight --mode github .    # GitHub API as bot
scripts/agent-git-setup.ps1 --preflight --mode git-only . # PowerShell
scripts/agent-git-setup.ps1 --preflight --mode github .
```

- Both modes require a linked worktree and verify effective author/committer name and numeric bot noreply email, including environment overrides.
- `git-only` does not require `GH_TOKEN`, `gh`, or network access.
- `github` requires `GH_TOKEN`, `AGENT_GIT_TOKEN_ACTOR`, `gh`, and network access. It compares the trusted token-provider actor to `AGENT_GIT_NAME` and uses `gh repo view` to confirm the token can access the current repository. The bundled App minter attests its actor using the App-JWT-authenticated slug; other providers must supply equivalent trusted metadata. `gh` consumes `GH_TOKEN` automatically; other API clients must pass it explicitly.
- Preflight is point-in-time, not continuous enforcement. Re-run after identity/token changes and after authentication failures.
- A skill is instructions, not a universal session hook. Guaranteed execution before each session requires the harness to call preflight as a lifecycle step.

## Example

```bash
git clone --depth 1 https://github.com/koalyptus/agent-git-setup.git /tmp/agent-git-setup 2>/dev/null || true
source <(/tmp/agent-git-setup/scripts/mint-token.sh --app-id [APP_ID] --pem [/path/to/app-private-key.pem] --shell)
export AGENT_GIT_NAME="[bot-name]"

/tmp/agent-git-setup/scripts/agent-git-setup.sh .    # Linux/macOS
/tmp/agent-git-setup/scripts/agent-git-setup.ps1 .   # Windows PowerShell
# Setup scopes commit identity to linked worktrees; the harness creates/selects the worktree.
scripts/agent-git-setup.sh --preflight --mode github <worktree-path>
# agent commits as myagent[bot]; gh/API calls use the verified bot token
```

## Pitfalls

- **Bot id = bot account, not human.** `AGENT_GIT_BOT_ID` (or resolved from `AGENT_GIT_NAME`) is what makes commits file under the **bot account**. Setup fails if it cannot resolve the bot ID; it never falls back to the human.
- **App install token cannot resolve bot id via API.** `GET /users/<app>[bot]` with an App install token fails (install tokens can't read arbitrary users). Use **unauthenticated** curl for bot id resolution. See `references/app-token-bot-id-limitation.md`.
- **File permissions = user's responsibility.** User `chmod 600` credentials file + PEM. Agent never sets/relaxes permissions. World-readable = anyone can mint bot tokens as the app.
- **Re-running is safe (idempotent).** Bot identity rewritten, not recreated. Future worktrees keep inheriting.
- **No origin is fine.** Script still sets bot commit author. `git push` uses human credential (by design). PR/API actor = bot via `GH_TOKEN`.
- **No worktreeConfig needed.** `includeIf` works on git 2.43+. Main repo's `.git` excluded by glob → stays human.
- **Token expiry.** ~1h. If expires mid-session, `gh`/API calls fail. Agent detects failure, re-runs `mint-token.sh` (or configured minter), retries.
- **Preflight is not a universal hook.** Run it in each actual agent worktree. Harness lifecycle integration is needed to guarantee it runs before every session.

## Push / PR as the bot

- Agent opens PRs as bot via `gh` + `GH_TOKEN`.
- Script only sets commit AUTHOR identity; never rewrites `origin`.
- Bot PR actor = `GH_TOKEN`. `git push` = human credential (by design).
- Run the matching `--preflight --mode git-only|github` before work.

## Windows / PowerShell

`scripts/agent-git-setup.ps1` — native Windows, same identity-only semantics (commit-author isolation via `includeIf`, no origin rewrite, no hooks, no worktree management). Same env vars as bash.

| Variable | Meaning |
|---|---|
| `AGENT_GIT_NAME` | Bot login used for commit attribution and actor verification. |
| `AGENT_GIT_BOT_ID` | Numeric bot ID for noreply email; required for offline setup. |
| `GH_TOKEN` | Required for GitHub-mode preflight and `gh`/API operations as the bot. |
| `AGENT_GIT_TOKEN_ACTOR` | Trusted actor login supplied by the token provider; required in GitHub mode. |
| `AGENT_GIT_ALLOW_TMP` | Opt-in for ephemeral location. |

```powershell
$env:AGENT_GIT_NAME = "myagent[bot]"   # replace with your bot's name (GitHub creates it as <app>[bot])
$env:AGENT_GIT_BOT_ID = "123456789"
# Set GH_TOKEN and AGENT_GIT_TOKEN_ACTOR from a trusted provider for GitHub mode.
scripts/agent-git-setup.ps1 <repo-dir>
```

## References

- `references/windows-support.md` — PowerShell port design, test parity, CI, known differences from bash.
