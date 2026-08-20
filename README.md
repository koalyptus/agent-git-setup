# agent-git-setup

Give an AI agent a bot identity in local git worktrees and/or on GitHub — backend-agnostic and token-agnostic.

## What it does

An AI coding agent should be able to commit and push as a distinct bot identity,
without that identity leaking into your own working tree. `agent-git-setup`
creates an isolated **git worktree** and configures it so that commits and pushes
made there are attributed to a bot, while your main checkout stays exactly as you.

It handles two distinct things:

1. **Local worktree commit identity.** Inside the worktree only, `user.name` and
   `user.email` are set to the bot identity. Commits authored there read as the
   bot. This is pure local git config — no token required.
2. **GitHub actor (push / API).** The worktree's `origin` remote is rewritten to
   use a token (`https://x-access-token:<token>@...`), so pushes are attributed
   to that identity. The same `GH_TOKEN` in the agent's environment also drives
   `gh`/API calls (PRs, issues, comments) as the bot — that part is owned by the
   backend/agent, not this script.

## What it is not

- **Not backend-specific.** Works the same under Hermes, OpenCode, Codex, Claude
  Code, or anything else. It never mentions a particular agent.
- **Not token-agnostic by accident — by design.** It does **not** mint tokens and
  contains no secrets. It expects `GH_TOKEN` to already be present in the
  environment (minted by whatever backend/agent you use) and only *consumes* it.
- **Not coupled to any worktree tool.** If `treehouse` is installed it is used to
  obtain the worktree; otherwise a plain `git worktree add` is used. Same result.
- **Not touching your main tree.** All configuration is scoped to the worktree.
  Your main repository and global git config are never modified.

## Usage

```bash
agent-git-setup <repo-dir> [worktree-name] [branch]
```

### Required environment

| Variable             | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `GH_TOKEN`           | A push-capable GitHub token (e.g. a GitHub App install token).       |
| `AGENT_GIT_NAME`     | Commit author name, e.g. `hermes-laptop[bot]`.                       |
| `AGENT_GIT_USER_ID`  | The bot **user** id (NOT the App id). Get it from                    |
|                      | `https://api.github.com/users/<name>` -> `.id`.                     |

### Optional environment

| Variable              | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `AGENT_GIT_SIGNINGKEY` | An SSH public key (`key::<pubkey>`) for a **verified** `[bot]` badge. |
| `AGENT_GIT_WORKTREE` | Worktree name (default: `agent`).                                   |
| `AGENT_GIT_BRANCH`   | Branch created in the worktree (default: `agent-work`).             |

### Example

```bash
export GH_TOKEN="$(mint-my-token)"            # backend-specific; not this script's job
export AGENT_GIT_NAME="hermes-laptop[bot]"
export AGENT_GIT_USER_ID="268339505"           # from api.github.com/users/hermes-laptop[bot]
export AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... bot@github"  # optional

agent-git-setup ~/dev/my-repo
# -> worktree at ~/dev/my-repo/.worktrees/agent
#    commits there: hermes-laptop[bot] <268339505+hermes-laptop[bot]@users.noreply.github.com>
#    your ~/dev/my-repo main tree: untouched
```

## Why a worktree

A worktree gives the agent its own checkout and its own `user.*` config, so the
bot identity applies *only* there. Your manual commits in the main tree remain
yours — no `git config` discipline required, no collision.

## Backend notes (how the token gets there)

`agent-git-setup` only consumes `GH_TOKEN`. How it arrives is the backend's job:

- **Hermes:** a launch wrapper mints the App install token and exports `GH_TOKEN`
  before starting the agent.
- **OpenCode / Codex / Claude Code:** configure the GitHub App credentials in the
  agent's settings; it mints the token for its own git/`gh` use.

The script is agnostic to all of the above.

## License

MIT.

