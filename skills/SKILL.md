---
name: agent-git-setup
description: "Set up an isolated git worktree where an AI agent commits/pushes as a distinct bot identity (<app>[bot]), leaving the human's working tree untouched."
version: 1.0.0
author: koalyptus
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [git, worktree, github, bot-identity, automation, agent]
---

# agent-git-setup

## When to use
- An agent is about to do git work (commits, pushes, PRs) and you want it
  attributed to a bot identity `<app>[bot]` rather than the human's account.
- You want that bot identity **isolated in a worktree** so the human's main
  checkout and global git config are never touched.
- Triggers: "commit as a bot", "agent should push as <bot>", "separate bot
  identity for the agent", "give the agent its own git identity", "worktree for
  the agent".

Do NOT use this for a human's normal interactive git login — that is a personal
PAT/SSH concern. This is for automation/bot attribution.

## Key concepts
- **Two identities, two mechanisms.** (1) The *commit author* is set by local
  `git config user.name/user.email` inside the worktree — no token needed.
  (2) The *push/API actor* is set by a token in the agent's environment
  (`GH_TOKEN`) used for the worktree `origin` remote and `gh`/API calls.
- **Worktree isolation.** All bot config is scoped to the worktree. The human's
  main tree stays theirs. No collision, no `git config` discipline required.
- **Token-agnostic.** The script does NOT mint tokens. It expects `GH_TOKEN` to
  already be present in the environment (minted by whatever backend/harness the
  agent runs under — e.g. a GitHub App install token at launch). It only consumes it.
- **Backend-neutral.** Works under any agent/harness. The script never names one.

## Prerequisites
- A git repository the agent should work in.
- `GH_TOKEN` in the environment: a push-capable GitHub token.
- The bot identity:
  - `AGENT_GIT_NAME` — e.g. `myagent[bot]`.
  - `AGENT_GIT_USER_ID` — the bot **user** id (NOT the App id). Fetch it:
    `curl -s https://api.github.com/users/<AGENT_GIT_NAME> | jq .id`
- (Optional) `AGENT_GIT_SIGNINGKEY` — an SSH public key (`key::<pubkey>`) for a
  verified `[bot]` commit badge. Requires the GitHub App to have commit signing
  enabled and its SSH key uploaded.

## Steps
1. Ensure `GH_TOKEN`, `AGENT_GIT_NAME`, `AGENT_GIT_USER_ID` are set in the
   agent's environment. (How the token arrives is the backend's job, not this skill's.)
2. Run the setup script, pointing at the repo:
   ```bash
   agent-git-setup.sh <repo-dir> [worktree-name] [branch]
   ```
   It creates `.worktrees/<worktree-name>/` (or uses `treehouse` if installed),
   sets per-worktree bot `user.name`/`user.email`, rewrites the worktree `origin`
   to `x-access-token:<GH_TOKEN>`, and optionally enables SSH signing.
3. Direct the agent to do its git work **inside that worktree path** (printed by
   the script). Commits there are `<app>[bot]`; the human's main tree is untouched.

## Example
```bash
export GH_TOKEN="$(mint-token)"          # backend-specific
export AGENT_GIT_NAME="myagent[bot]"
export AGENT_GIT_USER_ID="268339505"
export AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... bot@github"  # optional

agent-git-setup.sh ~/dev/my-repo
# agent works in ~/dev/my-repo/.worktrees/agent
```

## Pitfalls
- **Bot user id, not App id.** The commit email needs the *bot user* id
  (`api.github.com/users/<name>` -> `.id`), which differs from the App ID shown
  in GitHub App settings. Using the App id yields an unverified/odd email.
- **Re-running is safe (idempotent).** An existing worktree is reconfigured, not recreated.
- **No origin = no push actor.** If the repo has no `origin`, the script skips
  the remote rewrite and warns; add one manually if the agent should push as the bot.
- **Signing needs the App key.** `AGENT_GIT_SIGNINGKEY` only produces a Verified
  badge if the GitHub App has commit signing enabled and that SSH key uploaded.
  Without it, commits show as the bot but unverified.
- **Token expiry.** `GH_TOKEN` is typically short-lived (~1h). The script wires it
  once; for long sessions re-run with a fresh token.

## Repository
The script and this skill live together at
https://github.com/koalyptus/agent-git-setup — clone it and put
`agent-git-setup.sh` on PATH (or call it by absolute path).

