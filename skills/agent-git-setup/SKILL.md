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

1. **The agent writes the one-time credentials file** from the `GITHUB_APP_ID` /
   `GITHUB_APP_PEM` values in the user's prompt. These come from a GitHub App
   created beforehand (one-time, outside this flow) and its downloaded PEM; the
   user pastes the App ID and the PEM *path* into the prompt. The agent writes
   the file itself, once:
   ```bash
   CRED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-git-setup"
   mkdir -p "$CRED_DIR"
   umask 077   # ensures the file is created 600
   cat > "$CRED_DIR/credentials.env" <<EOF
   GITHUB_APP_ID=${GITHUB_APP_ID}
   GITHUB_APP_PEM=${GITHUB_APP_PEM}
   EOF
   chmod 600 "$CRED_DIR/credentials.env"
   ```
   (Override the path with `AGENT_GIT_CREDENTIALS=…` or `--credentials`.) The
   file holds only the public App ID and the **path** to the PEM — never the PEM
   bytes or a live token. The user's handle `GIT_USER_NAME` (e.g.
   `my-git-user-name`) is also given in the prompt; the skill/script resolves it
   to the numeric id via the GitHub API — no `curl | jq` by the user.
2. **Mint a token (arg-free, automatic from the credentials file):** every
   session the agent runs — no env vars, no `--app-id`/`--pem` needed:
   ```bash
   source <(./scripts/mint-token.sh --shell)
   # GH_TOKEN is now exported in the agent's shell
   ```
   If `GITHUB_APP_ID`/`GITHUB_APP_PEM` are already in the environment or passed
   as args, those win; otherwise the credentials file is sourced. This is why the
   agent is a GitHub actor **without you passing a token each session** — but the
   token itself is per-session (GitHub issues ~1h tokens; the script re-mints on
   demand). See the split note below.
3. **Set the bot identity (human gives the handle, agent resolves the id):**
   ```bash
   export AGENT_GIT_NAME="myagent[bot]"
   export GIT_USER_NAME="my-git-user-name"   # handle; the skill/script resolves it to the numeric id
   ```
4. **Run the setup once per repo.** The script writes the bot identity to the
   shared repo config (via git's `includeIf` conditional-include) so that **every
   worktree** of the repo — including ones created later — commits as the bot,
   while the main repo stays human. Run it from any worktree or the main repo:
   ```bash
   git clone --depth 1 https://github.com/koalyptus/agent-git-setup.git /tmp/agent-git-setup 2>/dev/null || true
   /tmp/agent-git-setup/scripts/agent-git-setup.sh .          # cwd = the repo
   # or: /tmp/agent-git-setup/scripts/agent-git-setup.sh /path/to/repo
   ```
   It does NOT create worktrees, does NOT create branches, and does NOT touch
   your main checkout. After writing, it prints `isolation verified — main
   tree untouched, all worktrees bot`. Future worktrees inherit the bot
   identity automatically — no re-run needed.

   **No worktreeConfig needed:** the script uses git's `includeIf` conditional
   include (`gitdir/i:**/.git/worktrees/**`), which works without
   `extensions.worktreeConfig` and needs no harness setup. The main repo's own
   `.git` directory does not match the glob, so it stays human.
5. **Work inside any worktree** the harness created. Every worktree already
   commits as `<name>[bot]`; `gh`/API calls use the bot; your main tree is
   untouched. **Agent must not** rewrite `origin` or set `remote.origin.url` in
   the worktree (or anywhere else) — that would leak the bot push credential
   into the main tree. The bot actor for `gh`/API (PRs, issues, comments) comes
   from `GH_TOKEN` in the agent's environment, **not** from a rewritten origin;
   plain `git push` uses the human's credential. The agent must not touch the
   main tree's `user.name`/`user.email` or global git config.

The token is short-lived (~1h); re-run step 2 for a fresh one in long sessions.

## Key concepts
- **Commit author = bot name + bot noreply email, push actor = human, gh/API = bot.** The worktree's own config file gets `user.name` (bot name) + `user.email` (bot noreply). `GH_TOKEN` in the environment drives `gh`/API (PRs, issues, comments) as the bot. Plain `git push` uses the human account owner's credential — the push actor is the human, by design. (The `scripts/agent-git-setup.sh` script never rewrites `origin`, because worktrees share remotes and rewriting would touch the main tree.)
- **Worktree isolation.** All bot config is scoped to the worktree's own config file. The human's main tree stays theirs. No collision, no `git config` discipline required.
- **Identity only — no worktree management.** The harness owns worktree creation, branching, hooks, and `core.hooksPath`. This skill only writes commit-author identity. It will not install guard hooks or push the branch; committing is the agent's job, pushing/opening PRs is the human's.
- **Token minting is fundamental.** The happy path requires a token, and this repo provides `scripts/mint-token.sh` to mint one from a GitHub App (RS256 JWT, needs only `python3` + `cryptography`). It is the expected, primary token source — not an optional extra. `scripts/agent-git-setup.sh` itself stays token-agnostic (it only *consumes* `GH_TOKEN`), which means other backends may supply a token their own way too, but for this repo's standalone flow `scripts/mint-token.sh` is what the agent uses.
- **Backend-neutral.** Works under any agent/harness.

## Prerequisites
- A git repository the agent should work in (any git >= 2.43). The harness may
  place the agent in a worktree; the script scopes bot identity to **all**
  worktrees via `includeIf` and needs no `worktreeConfig` extension.
- The bot identity:
  - `AGENT_GIT_NAME` — e.g. `myagent[bot]`.
  - `GIT_USER_NAME` — the GitHub handle whose numeric id becomes the noreply prefix (e.g. `my-git-user-name`). The script resolves it to the numeric id via the GitHub API (`GET /users/<handle>` — no token needed; when `GH_TOKEN` is set it is used as Bearer for higher rate limits / private). The commit email is `{bot_id}+{handle}@users.noreply.github.com` so the agent name appears in the commit list.
  - (Optional) `GH_TOKEN` — only if you also want `gh`/API as the bot (PRs, issues, comments, and API commits for Verified badge). Not needed for the local commit author.
- `python3` with the `cryptography` package if you use `scripts/mint-token.sh` (GitHub App path). Not needed for Git-only commit author.
- A GitHub App (App ID + PEM) — only if you use `scripts/mint-token.sh` for `gh`/API as the bot (see README §2). Not needed for Git-only.

## Steps
1. **If you need `gh`/API as the bot (PRs, issues, comments), this step is MANDATORY.** Mint and export `GH_TOKEN` — automatically from the one-time credentials file (see Happy path step 1): `source <(./scripts/mint-token.sh --shell)`. With the credentials file in place this needs **no env vars and no args**; `GH_TOKEN` is exported in-session. (If `GITHUB_APP_ID`/`GITHUB_APP_PEM` are already set in the environment, or passed as `--app-id`/`--pem`, those take precedence.) *Before* any `gh`/API call — without `GH_TOKEN`, `gh` silently falls back to the human's `gh auth` login and every comment/PR/issue is attributed to the human, not the bot. This is the single most common failure: the agent does git-commit work as the bot but posts to GitHub as the human because `GH_TOKEN` was never exported. Not needed for the local commit author alone. Then resolve `GIT_USER_NAME` to a numeric id via the public GitHub API (`GET /users/<handle>` — unauthenticated; add `Authorization: Bearer ${GH_TOKEN}` only when a token is set):
   `curl -s https://api.github.com/users/$GIT_USER_NAME | jq .id` (unauthenticated, public; add `Authorization: Bearer ${GH_TOKEN}` only when a `GH_TOKEN` is needed for `gh`/API).
2. Export `AGENT_GIT_NAME` / `GIT_USER_NAME`.
3. Run `scripts/agent-git-setup.sh <repo-dir>` once per repo — `<repo-dir>` is
   any worktree or the main repo (or omit it to use cwd). In practice,
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
- **Credentials file permissions are YOUR responsibility.** The one-time `credentials.env` holds only the public App ID + the **path** to the PEM (not the PEM bytes, not a token). You `chmod 600` it. The script never writes the PEM or a token to disk. If the file is world-readable, anyone who can read it can mint bot tokens as your app — so set perms deliberately.
- **Re-running is safe (idempotent).** The repo-wide bot identity is rewritten, not recreated; future worktrees keep inheriting it.
- **No origin is fine.** If the repo has no `origin`, the script still sets the bot commit author; only the (optional) push remote is absent. Plain `git push` uses the human account owner's push credential — the push actor is the human, by design.
- **No worktreeConfig needed.** The script uses git's `includeIf` conditional include, which works on git 2.43+ without any extension or harness setup. The main repo's own `.git` directory is excluded by the glob, so it stays human. `GH_TOKEN` in env drives `gh`/API as the bot — **not** rewriting `origin`.
- **Token expiry.** `GH_TOKEN` is typically short-lived (~1h). If a token expires while a sub-agent is still working, commits using that token will fail. The agent should detect the failure, re-run `scripts/mint-token.sh` (or its configured token minter) for a fresh `GH_TOKEN`, and retry the work.
- **Silent human fallback (the #1 gotcha).** If `GH_TOKEN` is NOT in the environment when the agent makes a `gh`/API call (comment, PR, issue), `gh` silently uses the human's `gh auth` login — so the post lands under the human, not the bot. There is no error. The only fix is to mint+export `GH_TOKEN` (skill step 2) *before* any `gh`/API call. If you provided a GitHub App prompt and still see human-attributed comments, suspect a missing `GH_TOKEN` first.
- **`cryptography` required for minting.** `scripts/mint-token.sh` needs `python3 -c "import cryptography"`. `scripts/agent-git-setup.sh` does NOT need it.
- **Push/PR is the human's action.** The script only sets commit AUTHOR identity. It never pushes and never opens a PR. Pushing and opening PRs are done by the human from the main repo.

## Repository
The script, the token minter, and this skill live together at
https://github.com/koalyptus/agent-git-setup — clone it and put
`scripts/agent-git-setup.sh` on PATH (or call it by absolute path).
