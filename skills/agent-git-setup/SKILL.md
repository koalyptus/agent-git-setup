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
- Bot identity scoped to the agent's worktree; human's main checkout + global git config untouched.
- Triggers: "commit as a bot", "agent should commit as <bot>", "separate bot identity for the agent".

Do NOT use for a human's normal git login — that is personal PAT/SSH. This is for automation/bot attribution.

## Scope (read first)

- **Identity-only.** Does NOT create worktrees, install hooks, rewrite remotes, or impose path/branch conventions. Those are the **harness's** job.
- Harness places agent in a worktree; this skill writes bot commit identity into that worktree.
- Keeps harness's own worktree/hook/branch management untouched.

## What persists vs what doesn't

- **Commit author identity (step 4):** set ONCE per repo via `includeIf`. Persists. Every future worktree inherits it automatically. No per-session action.
- **GH_TOKEN (step 2):** does NOT persist. Short-lived (~1h), env-only. Must be re-minted every new session. Without it, every `gh`/API call falls back to the human's `gh auth` silently.

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

   `AGENT_GIT_BOT_ID` = numeric id of `<app-slug>[bot]` (the account GitHub created for the App). It is the email prefix that makes commits file under the **bot account**, not the human. Resolve once via `gh api users/<app-slug>[bot]` or set directly. If absent, setup falls back to human noreply (bot name shows, but commit filed under human — silent, no error). `mint-token.sh --shell` re-emits it so it survives across sessions.

   Credentials file holds: public App ID + PEM **path** + bot id. Never the PEM bytes or a live token.

   `mint-token.sh` resolves creds: explicit `--credentials`/`AGENT_GIT_CREDENTIALS` → `credentials.d/credentials-<APP_ID>.env` → global `credentials.env`. One bot per repo = first-class.

2. **Every session: mint + export GH_TOKEN.** Before any `gh`/API call. No env vars, no args needed (credentials file has them).

   ```bash
   source <(scripts/mint-token.sh --shell)
   # GH_TOKEN exported in agent's shell
   ```

   If `GITHUB_APP_ID`/`GITHUB_APP_PEM` already in env or passed as `--app-id`/`--pem`, those win.

   **At the start of every new session**, the harness (or the agent as its very first action before any `gh`/API call) should do this. Without it, `gh` falls back to the human's `gh auth` silently (agent's shell inherits human's `gh` config when `GH_TOKEN` absent).

   No reliable harness-agnostic mechanism guarantees this happens each session — the skill can only state the expectation. Run `--preflight` before any `gh`/API work to detect a skipped session (fail-closed).

3. **Export bot identity vars.**

   ```bash
   export AGENT_GIT_NAME="myagent[bot]"   # replace with your bot's name (GitHub creates it as <app>[bot])
   export GIT_USER_NAME="my-git-user-name"         # HUMAN's handle — last-resort fallback only
   ```

   `AGENT_GIT_NAME`: bot's display name. Bot's numeric id resolved from it via `gh api users/<slug>[bot]` (public, no auth) — OR set `AGENT_GIT_BOT_ID` directly (offline-safe). The resolved id is persisted into the credentials file.

   `GIT_USER_NAME`: the **human account owner's** handle. Used ONLY as last-resort fallback when bot id cannot be resolved. Prefer `AGENT_GIT_BOT_ID`/`AGENT_GIT_NAME` so commits stay bot. Never treat as the agent's handle.

4. **Run setup once per repo.** Writes bot identity via `includeIf` into shared repo config. Every worktree (present + future) inherits. Main repo stays human.

   ```bash
   git clone --depth 1 https://github.com/koalyptus/agent-git-setup.git /tmp/agent-git-setup 2>/dev/null || true
   /tmp/agent-git-setup/scripts/agent-git-setup.sh .    # Linux/macOS
   /tmp/agent-git-setup/scripts/agent-git-setup.ps1 .   # Windows
   ```

   Does NOT create worktrees, branches, or touch main checkout. Prints isolation check. No `worktreeConfig` extension needed (`includeIf` works on git 2.43+).

5. **Agent works inside the harness's worktree.** Commits there = `<name>[bot]`. Main tree untouched.

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

## Before any git/gh work: --preflight

```bash
scripts/agent-git-setup.sh --preflight .   # Linux/macOS
scripts/agent-git-setup.ps1 --preflight .  # Windows
```

- Fails closed if: bot commit identity not in effect (not in a linked worktree of target repo, main checkout, detached checkout, separate clone) OR `GH_TOKEN` missing OR `GH_TOKEN` resolves to human (not bot).
- Verifies EFFECT (not path): `git config user.name` resolves to `AGENT_GIT_NAME`, so any proper worktree of the repo passes regardless of where it lives on disk.
- Verifies effective `gh` actor via `gh api user`: 403 = bot install token (pass), 200 type=User = human PAT (fail unless `AGENT_GIT_ALLOW_HUMAN_ACTOR=1`), anything else = cannot verify (warn, not block).
- Pre-work gate, NOT continuous enforcement. Does not watch for mid-session token expiry. Agent must detect auth failure mid-session, re-mint, retry.
- When `gh`/network unavailable: degrades to WARNING, not hard block (hermetic/offline runs still proceed — agent must still mint bot token as happy path).

## Consent to act as human (last resort only)

- `AGENT_GIT_ALLOW_HUMAN_ACTOR=1` — agent sets ONLY after account owner explicitly approves (out of band, e.g. chat). Account owner never types it by hand.
- Default unset. Human PAT in `GH_TOKEN` → `--preflight` fails closed until agent sets this on approval.
- Never use as workaround for missing bot token — mint bot token instead.

## Example

```bash
git clone --depth 1 https://github.com/koalyptus/agent-git-setup.git /tmp/agent-git-setup 2>/dev/null || true
source <(/tmp/agent-git-setup/scripts/mint-token.sh --app-id [APP_ID] --pem [/path/to/app-private-key.pem] --shell)
export AGENT_GIT_NAME="[bot-name]"
export GIT_USER_NAME="my-git-user-name"

/tmp/agent-git-setup/scripts/agent-git-setup.sh .    # Linux/macOS
/tmp/agent-git-setup/scripts/agent-git-setup.ps1 .   # Windows
# agent commits as myagent[bot]; opens PRs as myagent[bot] via gh + GH_TOKEN
```

## Pitfalls

- **Bot id = bot account, not human.** `AGENT_GIT_BOT_ID` (or resolved from `AGENT_GIT_NAME`) is what makes commits file under the **bot account**. Without it, commit filed under human (silent — no error, bot name shows but account is human). `GIT_USER_NAME` is human's handle, last-resort fallback only.
- **App install token cannot resolve bot id via API.** `GET /users/<app>[bot]` with an App install token fails (install tokens can't read arbitrary users). Use **unauthenticated** curl for bot id resolution. See `references/app-token-bot-id-limitation.md`.
- **File permissions = user's responsibility.** User `chmod 600` credentials file + PEM. Agent never sets/relaxes permissions. World-readable = anyone can mint bot tokens as the app.
- **Re-running is safe (idempotent).** Bot identity rewritten, not recreated. Future worktrees keep inheriting.
- **No origin is fine.** Script still sets bot commit author. `git push` uses human credential (by design). PR/API actor = bot via `GH_TOKEN`.
- **No worktreeConfig needed.** `includeIf` works on git 2.43+. Main repo's `.git` excluded by glob → stays human.
- **Token expiry.** ~1h. If expires mid-session, `gh`/API calls fail. Agent detects failure, re-runs `mint-token.sh` (or configured minter), retries.
- **gh/api calls need GH_TOKEN every session.** Without it, silent fallback to human's `gh auth`. No harness-agnostic guarantee — skill states expectation, `--preflight` detects misses.

## Push / PR as the bot

- Agent opens PRs as bot via `gh` + `GH_TOKEN`.
- Script only sets commit AUTHOR identity; never rewrites `origin`.
- Bot PR actor = `GH_TOKEN`. `git push` = human credential (by design).
- Run `--preflight` before any git/gh work.

## Windows / PowerShell

`scripts/agent-git-setup.ps1` — native Windows, same identity-only semantics (commit-author isolation via `includeIf`, no origin rewrite, no hooks, no worktree management). Same env vars as bash.

| Variable | Meaning |
|---|---|
|| `AGENT_GIT_NAME` | Commit author name, e.g. `myagent[bot]` (replace `myagent` with your bot's name). Preferred identity source. |
| `GIT_USER_NAME` | Human's GitHub handle. LAST-RESORT fallback only. |
| `GH_TOKEN` | GitHub token for gh/API as bot. Same semantics as bash. |
| `AGENT_GIT_BOT_ID` | Numeric bot id for noreply email. Offline-safe. |
| `AGENT_GIT_ALLOW_TMP` | Opt-in for ephemeral location. |

```powershell
$env:GH_TOKEN = (scripts/mint-token.sh --print-jwt)
$env:AGENT_GIT_NAME = "myagent[bot]"   # replace with your bot's name (GitHub creates it as <app>[bot])
$env:GIT_USER_NAME = "my-git-user-name"
scripts/agent-git-setup.ps1 <repo-dir>
```

## References

- `references/windows-support.md` — PowerShell port design, test parity, CI, known differences from bash.
