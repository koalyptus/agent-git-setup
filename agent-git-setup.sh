#!/usr/bin/env bash
# agent-git-setup.sh - give an AI agent its own git identity inside a worktree.
#
# Completely backend/agent-neutral. It does NOT mint tokens and contains no
# secrets. It expects GH_TOKEN (already minted by whatever backend/agent) and
# the desired bot identity in the environment, then sets up a git worktree
# where commits/pushes are attributed to that bot identity.
#
# If "treehouse" is installed it is used to obtain the worktree; otherwise a
# plain "git worktree add" is used. Either way the worktree is configured the
# same way.
#
# Env (required):
#   GH_TOKEN            a GitHub token with push rights (e.g. an App install token)
#   AGENT_GIT_NAME      commit author name, e.g. myagent[bot]
#   AGENT_GIT_USER_ID   the bot USER id (NOT the App id) from
#                       https://api.github.com/users/<name>  -> .id
# Env (optional):
#   AGENT_GIT_SIGNINGKEY  an SSH public key (key::<pubkey>) for verified [bot] commits
#   AGENT_GIT_WORKTREE   worktree name (default: agent)
#   AGENT_GIT_BRANCH     branch to create in the worktree (default: agent-work)
set -euo pipefail

REPO_DIR="${1:-}"
if [ -z "$REPO_DIR" ]; then
  echo "usage: agent-git-setup.sh <repo-dir> [worktree-name] [branch]" >&2
  exit 2
fi
if [ ! -d "$REPO_DIR/.git" ] && [ ! -f "$REPO_DIR/.git" ]; then
  echo "agent-git-setup.sh: $REPO_DIR is not a git repository" >&2
  exit 1
fi
WT_NAME="${2:-${AGENT_GIT_WORKTREE:-agent}}"
BRANCH="${3:-${AGENT_GIT_BRANCH:-agent-work}}"

: "${GH_TOKEN:?set GH_TOKEN (a push-capable GitHub token, e.g. App install token)}"
: "${AGENT_GIT_NAME:?set AGENT_GIT_NAME, e.g. myagent[bot]}"
: "${AGENT_GIT_USER_ID:?set AGENT_GIT_USER_ID (bot USER id, not the App id)}"

BOT_EMAIL="${AGENT_GIT_USER_ID}+${AGENT_GIT_NAME}@users.noreply.github.com"

cd "$REPO_DIR"
if command -v treehouse >/dev/null 2>&1; then
  echo "agent-git-setup.sh: using treehouse for worktree isolation"
  WT_PATH="$(treehouse --path "$WT_NAME" 2>/dev/null || true)"
  if [ -z "$WT" ]; then
    WT_PATH="$(treehouse 2>/dev/null | sed -n "s/.*worktree at \(.*\)/\1/p" | head -1)"
  fi
  if [ -z "$WT_PATH" ] || [ ! -d "$WT_PATH" ]; then
    echo "agent-git-setup.sh: treehouse did not yield a path; falling back to git worktree add" >&2
    WT_PATH="$REPO_DIR/.worktrees/$WT_NAME"
    git worktree add -B "$BRANCH" "$WT_PATH" 2>/dev/null || git worktree add "$WT_PATH"
  fi
else
  WT_PATH="$REPO_DIR/.worktrees/$WT_NAME"
  git worktree add -B "$BRANCH" "$WT_PATH" 2>/dev/null || git worktree add "$WT_PATH"
fi

echo "agent-git-setup.sh: configuring worktree at $WT_PATH"
git -C "$WT_PATH" config user.name "$AGENT_GIT_NAME"
git -C "$WT_PATH" config user.email "$BOT_EMAIL"

if git -C "$WT_PATH" remote get-url origin >/dev/null 2>&1; then
  BASE="$(git -C "$WT_PATH" remote get-url origin | sed -E "s#https://[^@]*@#https://#")"
  git -C "$WT_PATH" remote set-url origin "https://x-access-token:${GH_TOKEN}@${BASE#https://}"
  echo "agent-git-setup.sh: origin rewritten to use the bot token for pushes"
else
  echo "agent-git-setup.sh: no origin remote found; push actor not configured." >&2
  echo "  Add one manually if the agent should push as the bot." >&2
fi

if [ -n "${AGENT_GIT_SIGNINGKEY:-}" ]; then
  git -C "$WT_PATH" config gpg.format ssh
  git -C "$WT_PATH" config user.signingkey "$AGENT_GIT_SIGNINGKEY"
  git -C "$WT_PATH" config commit.gpgsign true
  echo "agent-git-setup.sh: commit signing enabled (verified [bot] badge)"
fi

echo "agent-git-setup.sh: done. Agent should work in: $WT_PATH"
echo "  commits there are attributed to $AGENT_GIT_NAME <$BOT_EMAIL>"
echo "  your main tree at $REPO_DIR is untouched."
