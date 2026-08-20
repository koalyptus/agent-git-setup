# agent-git-setup

Give an AI agent a bot identity in local git worktrees and/or on GitHub — backend-agnostic and token-agnostic.

## What it does

An AI coding agent should be able to commit and push as a distinct bot identity,
without that identity leaking into your own working tree. `agent-git-setup.sh`
creates an isolated **git worktree** and configures it so that commits and pushes
made there are attributed to a bot, while your main checkout stays exactly as you.

It handles two distinct things:

1. **Local worktree commit identity (required).** Inside the worktree only,
   `user.name` and `user.email` are set to the bot identity. Commits authored
   there read as the bot. This is pure local git config — no token required.
2. **GitHub actor (push / API).** The worktree's `origin` remote is rewritten to
   use a token (`https://x-access-token:<token>@...`), so pushes are attributed
   to that identity. The same `GH_TOKEN` in the agent's environment also drives
   `gh`/API calls (PRs, issues, comments) as the bot — that part is owned by the
   backend/agent, not this script.

## What it is not

- **Not backend-specific.** Works the same under any agent or harness. It never
  mentions a particular agent.
- **Not token-agnostic by accident — by design.** It does **not** mint tokens and
  contains no secrets. It expects `GH_TOKEN` to already be present in the
  environment (minted by whatever backend/agent you use) and only *consumes* it.
- **Not coupled to any worktree tool.** If `treehouse` is installed it is used to
  obtain the worktree; otherwise a plain `git worktree add` is used. Same result.
- **Not touching your main tree.** All configuration is scoped to the worktree.
  Your main repository and global git config are never modified.

## Usage

```bash
agent-git-setup.sh <repo-dir> [worktree-name] [branch]
```

### Required environment

| Variable             | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `GH_TOKEN`           | A push-capable GitHub token (e.g. a GitHub App install token).       |
| `AGENT_GIT_NAME`     | Commit author name, e.g. `myagent[bot]`.                            |
| `AGENT_GIT_USER_ID`  | The bot **user** id (NOT the App id). Get it from                    |
|                      | `https://api.github.com/users/<name>` -> `.id`.                     |

The commit author (`user.name` / `user.email`) is set from the required
variables above — it is **not** optional.

### Optional: verified commit signing

| Variable              | Meaning                                                              |
|----------------------|----------------------------------------------------------------------|
| `AGENT_GIT_SIGNINGKEY` | An SSH public key (`key::<pubkey>`) for a **verified** `[bot]` badge. |

Without this, commits still show as `<name>[bot]` but **unverified**. With it,
they get the green Verified checkmark.

### Defaults (override via environment or arguments)

| Variable              | Default     | Meaning                                  |
|----------------------|-------------|------------------------------------------|
| `AGENT_GIT_WORKTREE` | `agent`     | Worktree directory name.                |
| `AGENT_GIT_BRANCH`   | `agent-work`| Branch created in the worktree.          |

### Example

```bash
export GH_TOKEN="$(mint-my-token)"            # backend-specific; not this script's job
export AGENT_GIT_NAME="myagent[bot]"
export AGENT_GIT_USER_ID="268339505"           # from api.github.com/users/myagent[bot]
export AGENT_GIT_SIGNINGKEY="key::ssh-ed25519 AAAA... bot@github"  # optional

agent-git-setup.sh ~/dev/my-repo
# -> worktree at ~/dev/my-repo/.worktrees/agent
#    commits there: myagent[bot] <268339505+myagent[bot]@users.noreply.github.com>
#    your ~/dev/my-repo main tree: untouched
```

## Why a worktree

A worktree gives the agent its own checkout and its own `user.*` config, so the
bot identity applies *only* there. Your manual commits in the main tree remain
yours — no `git config` discipline required, no collision.

## Backend notes (how the token gets there)

`agent-git-setup.sh` only consumes `GH_TOKEN`. How it arrives is the backend's
job — any mechanism that places a push-capable token in the agent's environment
works (for example, a GitHub App install token minted at agent launch, or a
fine-grained token provisioned by the harness). The script is agnostic to all
of the above.

## License

MIT.

