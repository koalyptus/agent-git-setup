#!/usr/bin/env bash
#
# agent-git-setup.sh
#
# Give an AI agent its own git identity inside an isolated worktree.
#
# This script is completely backend/agent-neutral. It does NOT mint tokens and
# contains no secrets. It expects GH_TOKEN (already minted by whatever
# backend/agent is running) and the desired bot identity in the environment,
# then sets up a git worktree where commits are authored as that bot identity
# — while your main checkout stays exactly as you. The bot identity is the
# commit author only; plain `git push` uses your normal credential.
#
# If the "treehouse" tool is installed it is used to obtain the worktree;
# otherwise a plain "git worktree add" is used. Either way the worktree is
# configured the same way afterwards.
#
# Required environment variables:
#   AGENT_GIT_NAME    Commit author name, e.g. myagent[bot].
#   GIT_USER_NAME     GitHub handle whose numeric id becomes the noreply
#                     prefix (e.g. my-git-user-name). The script resolves
#                     it to an id via the GitHub API (public endpoint
#                     https://api.github.com/users/<handle>); no token
#                     needed for this step. See GIT_USER_ID below.
#   GIT_USER_ID       Numeric GitHub user id (alternative to GIT_USER_NAME).
#                     If set, used directly. If only GIT_USER_NAME is set,
#                     the script fetches the id via the public API.
#
# Optional environment variables:
#   GH_TOKEN              A push-capable GitHub token (e.g. an App install token).
#                         Only needed for gh/API as the bot (PRs, issues).
#                         Not needed for the local commit author.
#   AGENT_GIT_SIGNINGKEY  An SSH public key (key::<pubkey>) for a verified
#                         [bot] commit badge.
#   AGENT_GIT_WORKTREE    Worktree name (default: agent).
#   AGENT_GIT_BRANCH      Branch created in the worktree (default: agent-work).
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

# First argument is the target repository; remaining args are optional.
REPO_DIR="${1:-}"

if [ -z "$REPO_DIR" ]; then
	echo "usage: agent-git-setup.sh <repo-dir> [worktree-name] [branch]" >&2
	exit 2
fi

# The target must actually be a git repository.
if [ ! -d "$REPO_DIR/.git" ] && [ ! -f "$REPO_DIR/.git" ]; then
	echo "agent-git-setup.sh: $REPO_DIR is not a git repository" >&2
	exit 2
fi

# Worktree name and branch come from arguments or environment, with defaults.
WT_NAME="${2:-${AGENT_GIT_WORKTREE:-agent}}"
BRANCH="${3:-${AGENT_GIT_BRANCH:-agent-work}}"

# ---------------------------------------------------------------------------
# Required environment
# ---------------------------------------------------------------------------

# Bail out early (with a helpful message) if a required var is missing.
: "${AGENT_GIT_NAME:?set AGENT_GIT_NAME, e.g. myagent[bot]}"
# GIT_USER_NAME (handle) is the human-facing input. GIT_USER_ID is a hidden
# fallback for hermetic tests / offline use. If only the handle is set, resolve
# it via the public GitHub API (GET /users/<handle> is unauthenticated);
# when GH_TOKEN is set, use it as Bearer for higher rate limits / private.
if [ -n "${GIT_USER_ID:-}" ]; then
	_GIT_UID="$GIT_USER_ID"
elif [ -n "${GIT_USER_NAME:-}" ]; then
	# GET /users/<handle> is public; add Bearer only when GH_TOKEN is set.
	if [ -n "${GH_TOKEN:-}" ]; then
		_GIT_UID="$(curl -sf -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github.v3+json" "https://api.github.com/users/$GIT_USER_NAME" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
	else
		_GIT_UID="$(curl -sf -H "Accept: application/vnd.github.v3+json" "https://api.github.com/users/$GIT_USER_NAME" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
	fi
	if [ -z "${_GIT_UID:-}" ] || [ "$_GIT_UID" = "None" ]; then
		echo "agent-git-setup.sh: failed to resolve GIT_USER_NAME=$GIT_USER_NAME to an id (check handle; GH_TOKEN optional but helps for rate limits/private)" >&2
		exit 1
	fi
	GIT_USER_ID="$_GIT_UID"
else
	echo "agent-git-setup.sh: set GIT_USER_NAME (GitHub handle, e.g. my-git-user-name) or GIT_USER_ID" >&2
	exit 2
fi

# GitHub noreply email derived from the bot user id + name.
# This is what makes the commit author show as <name>[bot] on GitHub.
BOT_EMAIL="${GIT_USER_ID}+${AGENT_GIT_NAME}@users.noreply.github.com"

# ---------------------------------------------------------------------------
# Locate / create the worktree
# ---------------------------------------------------------------------------

cd "$REPO_DIR"

# Default location for a plain git worktree.
WT_PATH="$REPO_DIR/.worktrees/$WT_NAME"

# Prefer treehouse when it is available on PATH.
if command -v treehouse >/dev/null 2>&1; then
	echo "agent-git-setup.sh: treehouse detected; using it for worktree isolation"

	# Ask treehouse for the path of this named worktree (non-interactively).
	THPATH="$(treehouse --path "$WT_NAME" 2>/dev/null || true)"

	if [ -n "$THPATH" ] && [ -d "$THPATH" ]; then
		WT_PATH="$THPATH"
	else
		# treehouse did not yield a usable path; fall back to git worktree add.
		echo "agent-git-setup.sh: treehouse did not yield a path; falling back to git worktree add" >&2
	fi
fi

# Create the worktree only if it does not already exist (idempotent).
if [ -d "$WT_PATH/.git" ] || [ -f "$WT_PATH/.git" ]; then
	echo "agent-git-setup.sh: worktree already exists at $WT_PATH (reconfiguring)"
else
	# Plain git worktree add (only when we own the path).
	if [ "$WT_PATH" = "$REPO_DIR/.worktrees/$WT_NAME" ]; then
		git worktree add -B "$BRANCH" "$WT_PATH" 2>/dev/null || git worktree add "$WT_PATH"
	fi
fi

# ---------------------------------------------------------------------------
# Configure the worktree with the bot identity (commit-author isolation only)
# ---------------------------------------------------------------------------

echo "agent-git-setup.sh: configuring worktree at $WT_PATH"

# IMPORTANT: a linked worktree shares the MAIN repo's config and remotes.
# "git -C $WT_PATH config" would resolve to the main repo and LEAK the bot
# identity into the human's tree. To truly isolate, we write to the worktree's
# OWN config file, which git reads in preference for that worktree only.
WT_CONFIG="$REPO_DIR/.git/worktrees/$WT_NAME/config"
mkdir -p "$(dirname "$WT_CONFIG")"

# (1) Commit author — scoped to the worktree only (main tree untouched).
git config -f "$WT_CONFIG" user.name "$AGENT_GIT_NAME"
git config -f "$WT_CONFIG" user.email "$BOT_EMAIL"

# (2) Push actor is NOT configured here. Git worktrees share remotes, so we
#     do not rewrite origin (that would change the human's main tree). The bot
#     gh/API actor (PRs, issues, comments) is provided by GH_TOKEN in the
#     agent's environment, which drives gh/API calls as the bot. Plain
#     `git push` uses the repo's normal credential — the push actor is you.
#     credential — by design, so the main tree is never touched.

# (3) Optional: verified [bot] commit signing via the App SSH key.
# The key is the public key literal (key::<pubkey>). For SSH signing to actually
# work, the corresponding PRIVATE key must be loaded in ssh-agent:
#   eval "$(ssh-agent -s)" && ssh-add /path/to/myagent-signing
# Add that to your shell rc so it's always available when the agent commits.
if [ -n "${AGENT_GIT_SIGNINGKEY:-}" ]; then
	git config -f "$WT_CONFIG" gpg.format ssh
	git config -f "$WT_CONFIG" user.signingkey "$AGENT_GIT_SIGNINGKEY"
	git config -f "$WT_CONFIG" commit.gpgsign true
	echo "agent-git-setup.sh: commit signing enabled (verified [bot] badge)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo "agent-git-setup.sh: done. Agent should work in: $WT_PATH"
echo "  commits there are attributed to $AGENT_GIT_NAME <$BOT_EMAIL>"
echo "  your main tree at $REPO_DIR is untouched."
