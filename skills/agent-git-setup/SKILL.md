---
name: agent-git-setup
description: "Set up a bot git identity (<name>[bot]) for an AI agent's worktree so commits are attributed to the bot, leaving the human's working tree untouched. Identity-only: the harness owns the worktree."
version: 2.0.0
author: koalyptus
license: MIT
platforms: [linux, macos]
---

# Agent Git Setup

Give an AI agent its own bot identity so its git commits are attributed to
`<name>[bot]` instead of the human's account.

## When to use
- An agent is about to do git work (commits, PRs) and you want it
  attributed to a bot identity `<name>[bot]` rather than the human's account.
- You want that bot identity **scoped to the agent's worktree** so the human's
  main checkout and global git config are never touched.
- Triggers: "commit as a bot", "agent should commit as <bot>", "separate bot
  identity for the agent", "give the agent its own git identity".

Do NOT use this for a human's normal interactive git login — that is a personal
PAT/SSH concern. This is for automation/bot attribution.

## Scope (important)

This skill is **identity-only**. It does NOT create worktrees, does NOT install
hooks, does NOT rewrite remotes, and does NOT impose a path or branch
convention. Those are the **harness's** responsibility. The harness places the
agent in a worktree; this skill only writes the bot commit identity into that
worktree's OWN config. This keeps it from interfering with any harness's own
worktree/hook/branch management.

## Design

**Local commits** use the **bot noreply email** so the agent name appears in the
GitHub commit list. No SSH signing by default — the "verified" badge is
not worth the key management complexity for ephemeral agent environments
(matches industry standard: Codex, Claude Code, Cursor, Copilot).

**Git-only flow:** bot noreply, no signing → agent name shows, no badge.
**GitHub App flow:** bot noreply for local commits + `gh` with `GH_TOKEN` for
API commits (GitHub signs server-side → agent name + Verified badge).

## Happy path (end-to-end, self-contained)

This skill is meant to be used standalone: the agent installs the bot identity
without needing any other tooling. Everything lives in this repo
(`scripts/agent-git-setup.sh`, `scripts/mint-token.sh`, `skills/agent-git-setup/SKILL.md`,
and the bundled copies in `skills/agent-git-setup/scripts/` so skill-install
harnesses can fetch the support files).

> **Skill bundle:** `skills/agent-git-setup/scripts/*.sh` is a bundled copy of
> `scripts/*.sh` so a skill-install harness can fetch the support files. The
> repo root is the source of truth. If you edit a root script, run
> `make sync-skill-scripts` and commit the bundle copy in the same commit.

1. **One-time, outside the agent:** create a GitHub App (see README "GitHub App
   setup"), download its PEM, install it on the target repos, and note the
   App ID, the PEM path, and your handle `GIT_USER_NAME`
   (e.g. `my-git-user-name` — the skill/script will resolve it to the numeric id
   via the GitHub API; you never run `curl | jq`).
2. **Mint a token** with the repo's own helper:
   ```bash
   source <(./scripts/mint-token.sh --app-id "$APP_ID" --pem "$PEM_PATH" --shell)
   # GH_TOKEN is now exported in the agent's shell
   ```
3. **Set the bot identity (human gives the handle, agent resolves the id):**
   ```bash
   export AGENT_GIT_NAME="myagent[bot]"
   export GIT_USER_NAME="my-git-user-name"   # handle; the skill/script resolves it to the numeric id
   ```
4. **Run the setup** against the worktree the harness already created for the
   agent. The script operates on the worktree the agent is already in (cwd), or
   on a path you pass:
   ```bash
   git clone --depth 1 https://github.com/koalyptus/agent-git-setup.git /tmp/agent-git-setup 2>/dev/null || true
   /tmp/agent-git-setup/scripts/agent-git-setup.sh .          # cwd = the agent's worktree
   # or: /tmp/agent-git-setup/scripts/agent-git-setup.sh /path/to/worktree
   ```
   The script writes `user.name`/`user.email` to the worktree's OWN config only
   and prints an isolation check (`worktree user.name` = bot, `main tree
   user.name` = human) that fails loudly if the worktree config is not being
   read. It does NOT create the worktree and does NOT create a branch.

   **worktreeConfig extension:** identity isolation requires git 2.43+
   `extensions.worktreeConfig` to be enabled in the MAIN repo. The harness that
   created the worktree is expected to have enabled it. If it is missing, the
   script errors and tells the agent to **ASK THE HUMAN** whether they may enable
   it (`git config extensions.worktreeConfig true` in the main repo, one-time).
   The script never enables it silently — that writes to the human's main repo.
5. **Work inside the worktree** the harness created. Commits there are
   `<name>[bot]`; `gh`/API calls use the bot; your main tree is untouched.
   **Agent must not** rewrite `origin` or set `remote.origin.url` in the
   worktree (or anywhere else) — that would leak the bot push credential into
   the main tree. The bot actor for `gh`/API (PRs, issues, comments) comes from
   `GH_TOKEN` in the agent's environment, **not** from a rewritten origin; plain
   `git push` uses the human's credential. The agent must not touch the main
   tree's `user.name`/`user.email` or global git config.

The token is short-lived (~1h); re-run step 2 for a fresh one in long sessions.

## Key concepts
- **Commit author = bot name + bot noreply email, push actor = human, gh/API = bot.** The worktree's own config file gets `user.name` (bot name) + `user.email` (bot noreply). `GH_TOKEN` in the environment drives `gh`/API (PRs, issues, comments) as the bot. Plain `git push` uses the human account owner's credential — the push actor is the human, by design. (The `scripts/agent-git-setup.sh` script never rewrites `origin`, because worktrees share remotes and rewriting would touch the main tree.)
- **Worktree isolation.** All bot config is scoped to the worktree's own config file. The human's main tree stays theirs. No collision, no `git config` discipline required.
- **Identity only — no worktree management.** The harness owns worktree creation, branching, hooks, and `core.hooksPath`. This skill only writes commit-author identity. It will not install guard hooks or push the branch; committing is the agent's job, pushing/opening PRs is the human's.
- **Token minting is fundamental.** The happy path requires a token, and this repo provides `scripts/mint-token.sh` to mint one from a GitHub App (RS256 JWT, needs only `python3` + `cryptography`). It is the expected, primary token source — not an optional extra. `scripts/agent-git-setup.sh` itself stays token-agnostic (it only *consumes* `GH_TOKEN`), which means other backends may supply a token their own way too, but for this repo's standalone flow `scripts/mint-token.sh` is what the agent uses.
- **Backend-neutral.** Works under any agent/harness.

## Prerequisites
- A git **worktree** the agent should work in, created by the harness, with
  `extensions.worktreeConfig=true` enabled in the main repo (requires **git >= 2.43**
  for per-worktree isolation; the script fails fast and asks the human to enable it
  if missing).
- The bot identity:
  - `AGENT_GIT_NAME` — e.g. `myagent[bot]`.
  - `GIT_USER_NAME` — the GitHub handle whose numeric id becomes the noreply prefix (e.g. `my-git-user-name`). The script resolves it to the numeric id via the GitHub API (`GET /users/<handle>` — no token needed; when `GH_TOKEN` is set it is used as Bearer for higher rate limits / private). The commit email is `{bot_id}+{AGENT_GIT_NAME}@users.noreply.github.com` so the agent name appears in the commit list.
  - (Optional) `GH_TOKEN` — only if you also want `gh`/API as the bot (PRs, issues, comments, and API commits for Verified badge). Not needed for the local commit author.
- `python3` with the `cryptography` package if you use `scripts/mint-token.sh` (GitHub App path). Not needed for Git-only commit author.
- A GitHub App (App ID + PEM) — only if you use `scripts/mint-token.sh` for `gh`/API as the bot (see README §2). Not needed for Git-only.

## Steps
1. If you need `gh`/API as the bot (PRs, issues), mint and export `GH_TOKEN` (step 2 of the Happy path) or otherwise ensure a push-capable token is in the environment. Not needed for commit author alone. Then resolve `GIT_USER_NAME` to a numeric id via the public GitHub API (`GET /users/<handle>` — unauthenticated; add `Authorization: Bearer *** only when a token is set):
   `curl -s https://api.github.com/users/$GIT_USER_NAME | jq .id` (unauthenticated, public; add `Authorization: Bearer *** only when a `GH_TOKEN` is needed for `gh`/API).
2. Export `AGENT_GIT_NAME` / `GIT_USER_NAME`.
3. Run `scripts/agent-git-setup.sh <worktree-dir>` where `<worktree-dir>` is the
   worktree the harness created for the agent (or omit it to use cwd). In practice,
   clone once to `/tmp` and run from there:
   ```bash
   git clone --depth 1 https://github.com/koalyptus/agent-git-setup.git /tmp/agent-git-setup 2>/dev/null || true
   /tmp/agent-git-setup/scripts/agent-git-setup.sh .
   ```
4. Direct the agent to do its git work **inside the worktree the harness created**. Commits there are `<name>[bot]`; the human's main tree is untouched.

## Example
```bash
# if needed, fetch the helper (agent clones deterministically; see Happy path step 4)
git clone --depth 1 https://github.com/koalyptus/agent-git-setup.git /tmp/agent-git-setup 2>/dev/null || true
source <(/tmp/agent-git-setup/scripts/mint-token.sh --app-id 4646191 --pem /path/to/myagent.pem --shell)
export AGENT_GIT_NAME="myagent[bot]"
export GIT_USER_NAME="my-git-user-name"   # handle; resolved to numeric id via API

/tmp/agent-git-setup/scripts/agent-git-setup.sh .   # cwd = the agent's worktree (harness-made)
# agent commits as myagent[bot]; push/PR is the human's action
```

## Pitfalls
- **GitHub handle, not numeric id.** The human provides `GIT_USER_NAME` (e.g. `my-git-user-name`). Either the skill (step 2 above) or `scripts/agent-git-setup.sh` resolves it to the numeric id via the public API (`GET https://api.github.com/users/$GIT_USER_NAME` — no auth; Bearer added only when `GH_TOKEN` is set). The commit email is `{bot_id}+{AGENT_GIT_NAME}@users.noreply.github.com` — agent name appears in the commit list. `GIT_USER_ID` can still be set directly for hermetic tests or offline use, but it is never asked for in the prompt.
- **Re-running is safe (idempotent).** The worktree identity is reconfigured, not recreated.
- **No origin is fine.** If the repo has no `origin`, the script still sets the bot commit author; only the (optional) push remote is absent. Plain `git push` uses the human account owner's push credential — the push actor is the human, by design.
- **worktreeConfig must be enabled by the harness.** The script reads `extensions.worktreeConfig` (git 2.43+) so the per-worktree config is actually read; without it the bot identity would leak. The script does NOT enable it — if missing, it tells the agent to ask the human. `GH_TOKEN` in env drives `gh`/API as the bot — **not** rewriting `origin`.
- **Token expiry.** `GH_TOKEN` is typically short-lived (~1h). If a token expires while a sub-agent is still working, commits using that token will fail. The agent should detect the failure, re-run `scripts/mint-token.sh` (or its configured token minter) for a fresh `GH_TOKEN`, and retry the work.
- **`cryptography` required for minting.** `scripts/mint-token.sh` needs `python3 -c "import cryptography"`. `scripts/agent-git-setup.sh` does NOT need it.
- **Push/PR is the human's action.** The script only sets commit AUTHOR identity. It never pushes and never opens a PR. Pushing and opening PRs are done by the human from the main repo.

## Repository
The script, the token minter, and this skill live together at
https://github.com/koalyptus/agent-git-setup — clone it and put
`scripts/agent-git-setup.sh` on PATH (or call it by absolute path).
