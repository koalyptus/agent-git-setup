---
name: agent-git-setup
description: "Set up an isolated git worktree where an AI agent commits as a distinct bot identity (<name>[bot]), leaving the human's working tree untouched."
version: 1.0.0
author: koalyptus
license: MIT
platforms: [linux, macos]
---

# Agent Git Setup

Give an AI agent its own bot identity in a git worktree.

## When to use
- An agent is about to do git work (commits, PRs) and you want it
  attributed to a bot identity `<name>[bot]` rather than the human's account.
- You want that bot identity **isolated in a worktree** so the human's main
  checkout and global git config are never touched.
- Triggers: "commit as a bot", "agent should commit as <bot>", "separate bot
  identity for the agent", "give the agent its own git identity", "worktree for
  the agent".

Do NOT use this for a human's normal interactive git login — that is a personal
PAT/SSH concern. This is for automation/bot attribution.

## Happy path (end-to-end, self-contained)

This skill is meant to be used standalone: the agent installs the bot identity
without needing any other tooling. Everything lives in this repo
(`agent-git-setup.sh`, `mint-token.sh`, `skills/agent-git-setup/SKILL.md`).

0. **One-time, outside the agent:** create a GitHub App (see README "GitHub App
   setup"), download its PEM, install it on the target repos, and note the
   App ID, the PEM path, and your handle `GIT_USER_NAME`
   (e.g. `my-git-user-name` — the skill/script will resolve it to the numeric id
   via the GitHub API; you never run `curl | jq`).
1. **Mint a token** with the repo's own helper:
   ```bash
   source <(./mint-token.sh --app-id "$APP_ID" --pem "$PEM_PATH" --shell)
   # GH_TOKEN is now exported in the agent's shell
   ```
2. **Set the bot identity (human gives the handle, agent resolves the id):**
   ```bash
   export AGENT_GIT_NAME="myagent[bot]"
   export GIT_USER_NAME="my-git-user-name"   # handle; the skill/script resolves it to the numeric id
   # optional, for a verified [bot] badge:
   export AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... bot@github"
   ```
3. **Run the setup** against the repo:
   ```bash
   agent-git-setup.sh <repo-dir> [worktree-name] [branch]
   ```
   The `agent-git-setup.sh` script creates `.worktrees/<worktree-name>/`, writes
   the bot `user.name`/`user.email` to the worktree's own config file (main
   tree untouched), and optionally enables SSH signing. It does NOT rewrite
   `origin`.
4. **Work inside the worktree** the script printed. Commits there are
   `<name>[bot]`; `gh`/API calls use the bot; your main tree is untouched.

The token is short-lived (~1h); re-run step 1 for a fresh one in long sessions.

## Key concepts
- **Commit author = bot, push actor = human, gh/API = bot.** The worktree's own
  config file gets `user.name`/`user.email` (the commit author). `GH_TOKEN` in
  the environment drives `gh`/API (PRs, issues, comments) as the bot. Plain
  `git push` uses the human account owner's credential — the push actor is the
  human, by design. (The `agent-git-setup.sh` script never rewrites `origin`,
  because worktrees share remotes and rewriting would touch the main tree.)
- **Worktree isolation.** All bot config is scoped to the worktree's own config
  file. The human's main tree stays theirs. No collision, no `git config`
  discipline required.
- **Token minting is fundamental.** The happy path requires a token, and this
  repo provides `mint-token.sh` to mint one from a GitHub App (RS256 JWT, needs
  only `python3` + `cryptography`). It is the expected, primary token source —
  not an optional extra. `agent-git-setup.sh` itself stays token-agnostic (it
  only *consumes* `GH_TOKEN`), which means other backends may supply a token
  their own way too, but for this repo's standalone flow `mint-token.sh` is what
  the agent uses.
- **Backend-neutral.** Works under any agent/harness.

## Prerequisites
- A git repository the agent should work in.
- A GitHub App (App ID + PEM) — one-time, set up by the GitHub account owner
  (the human), not by the agent — see README "GitHub App setup".
- The bot identity:
  - `AGENT_GIT_NAME` — e.g. `myagent[bot]`.
  - `GIT_USER_NAME` — the GitHub handle whose numeric id becomes the noreply
    prefix (e.g. `my-git-user-name`). The skill resolves it to
    the numeric id via the GitHub API (needs `GH_TOKEN`).
- `python3` with the `cryptography` package (for `mint-token.sh`).
- (Optional) `AGENT_GIT_SIGNINGKEY` — an SSH public key (`key::<pubkey>`) for a
  verified `[bot]` commit badge. Requires the GitHub App to have commit signing
  enabled and its SSH key uploaded.

## Steps
1. Mint and export `GH_TOKEN` (step 1 of the Happy path), or otherwise ensure a
   push-capable token is in the environment. Then resolve `GIT_USER_NAME` to a
   numeric id via the GitHub API (using `GH_TOKEN`):
   `curl -s -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/users/$GIT_USER_NAME | jq .id`.
2. Export `AGENT_GIT_NAME` / `GIT_USER_NAME` (and optionally
   `AGENT_GIT_SIGNINGKEY`).
3. Run `agent-git-setup.sh <repo-dir> [worktree-name] [branch]`
     (step 3 of the Happy path — the actual setup step).
4. Direct the agent to do its git work **inside the printed worktree path**.
   Commits there are `<name>[bot]`; the human's main tree is untouched.

## Example
```bash
# mint + export the token (repo's own helper)
source <(./mint-token.sh --app-id 4646191 --pem ~/.ssh/myagent.pem --shell)
export AGENT_GIT_NAME="myagent[bot]"
export GIT_USER_NAME="my-git-user-name"   # handle; resolved to numeric id via API
export AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... bot@github"  # optional

agent-git-setup.sh ~/dev/my-repo
# agent works in ~/dev/my-repo/.worktrees/agent
```

## Pitfalls
- **GitHub handle, not numeric id.** The human provides `GIT_USER_NAME` (e.g.
  `my-git-user-name`). Either the skill (step 1 above) or
  `agent-git-setup.sh` resolves it to the numeric id via
  `curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/users/$GIT_USER_NAME | jq .id`
  and builds the noreply email. For the Git-only path the handle is the GitHub
  account owner; for the GitHub App path it is the bot handle itself (the id is
  the bot user's id). `GIT_USER_ID` can still be set directly for hermetic
  tests or offline use, but it is never asked for in the prompt.
- **Re-running is safe (idempotent).** An existing worktree is reconfigured, not recreated.
- **No origin is fine.** If the repo has no `origin`, the script still sets the
  bot commit author; only the (optional) push remote is absent. Plain
  `git push` uses the human account owner's push credential — the push actor is
  the human, by design.
- **Signing needs the App key.** `AGENT_GIT_SIGNINGKEY` only produces a Verified
  badge if the GitHub App has commit signing enabled and that SSH key uploaded.
  Without it, commits show as the bot but unverified.
- **Token expiry.** `GH_TOKEN` is typically short-lived (~1h). If a token
  expires while a sub-agent is still working, commits using that token will
  fail. The agent should detect the failure, re-run `mint-token.sh` (or its
  configured token minter) for a fresh `GH_TOKEN`, and retry the work.
- **`cryptography` required for minting.** `mint-token.sh` needs
  `python3 -c "import cryptography"`. `agent-git-setup.sh` does NOT need it.

## Repository
The script, the token minter, and this skill live together at
https://github.com/koalyptus/agent-git-setup — clone it and put
`agent-git-setup.sh` on PATH (or call it by absolute path).

