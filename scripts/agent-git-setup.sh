#!/usr/bin/env bash
#
# agent-git-setup.sh
#
# Give an AI agent its own git identity inside an isolated worktree.
#
# This script is completely backend/agent-neutral. It does NOT mint tokens and
# contains no secrets. It expects the desired bot identity in the environment,
# then sets up a git worktree where commits are authored as that bot identity
# — while your main checkout stays exactly as you. The bot identity is the
# commit author only; plain `git push` uses your normal credential.
#
# DESIGN (matches industry standard: Codex, Claude Code, Cursor, Copilot):
#   Local commits use the BOT noreply email so the agent name appears in the
#   GitHub commit list. No SSH signing by default — the "verified" badge is
#   not worth the key management complexity for ephemeral agent environments.
#
#   Git-only flow: bot noreply, no signing → agent name shows, no badge.
#   GitHub App flow: bot noreply for local commits + `gh` with `GH_TOKEN` for
#   API commits (GitHub signs server-side → agent name + Verified badge).
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
#   GH_TOKEN              A GitHub token (e.g. an App install token) for
#                         `gh`/API operations as the bot (PRs, issues,
#                         comments, and API commits for Verified badge).
#   AGENT_GIT_SIGNINGKEY  DEPRECATED — SSH signing does not verify for bot
#                         noreply emails. Kept for backward compatibility
#                         but has no effect on bot identity commits.
#   AGENT_GIT_WORKTREE    Worktree name (default: agent).
#   AGENT_GIT_BRANCH      Branch created in the worktree (default: agent-work).
#   AGENT_GIT_WORKTREE_ROOT Worktree root for standalone mode (default: ~/.agent-git-setup).
#                           Treehouse, when present, overrides this.
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

# Commit email: use bot noreply so the agent name appears in the GitHub commit list.
# The bot id is resolved via the public API (GET /users/<bot> works without auth).
# This matches the industry standard (Codex, Claude Code, Cursor, Copilot).
# AGENT_GIT_BOT_ID is a hidden override for hermetic tests (no network).
if [ -n "${AGENT_GIT_BOT_ID:-}" ]; then
	COMMIT_EMAIL="${AGENT_GIT_BOT_ID}+${AGENT_GIT_NAME}@users.noreply.github.com"
else
	_APP_BOT_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "${AGENT_GIT_NAME}" 2>/dev/null || true)"
	_APP_BOT_ID="$(curl -sf "https://api.github.com/users/${_APP_BOT_ENC}" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
	if [ -n "${_APP_BOT_ID:-}" ] && [ "${_APP_BOT_ID}" != "None" ] && [ "${_APP_BOT_ID}" != "" ]; then
		COMMIT_EMAIL="${_APP_BOT_ID}+${AGENT_GIT_NAME}@users.noreply.github.com"
	elif [ -n "${GIT_USER_NAME:-}" ]; then
		COMMIT_EMAIL="${GIT_USER_ID}+${GIT_USER_NAME}@users.noreply.github.com"
	else
		COMMIT_EMAIL="${GIT_USER_ID}+${AGENT_GIT_NAME}@users.noreply.github.com"
	fi
fi

# ---------------------------------------------------------------------------
# Locate / create the worktree
# ---------------------------------------------------------------------------

# Resolve REPO_DIR to absolute so basename is correct when invoked as "."
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
cd "$REPO_DIR"

# Default location for a plain git worktree: outside the repo so the host repo
# is never polluted (no .gitignore commit, no git add . accident).
# Standalone (no treehouse): ~/.agent-git-setup/<repo-basename>/<WT_NAME>
# Override with AGENT_GIT_WORKTREE_ROOT (e.g. for tests / custom XDG).
REPO_SLUG="$(basename "$REPO_DIR")"
WT_ROOT="${AGENT_GIT_WORKTREE_ROOT:-$HOME/.agent-git-setup}"
WT_PATH="$WT_ROOT/$REPO_SLUG/$WT_NAME"

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
	# Standalone worktree (we own the path when treehouse is absent).
	# When treehouse is present, WT_PATH was overridden above; don't add twice.
	if [ "$WT_PATH" = "$WT_ROOT/$REPO_SLUG/$WT_NAME" ]; then
		mkdir -p "$(dirname "$WT_PATH")"
		git worktree add -B "$BRANCH" "$WT_PATH" 2>/dev/null || git worktree add "$WT_PATH"
	fi
fi

# Enable git 2.43+ `extensions.worktreeConfig` — without this, git ignores the
# per-worktree config file (.git/worktrees/<name>/config) and the bot identity
# still leaks into the shared main config. Enabling it is safe and only tells git
# to read each worktree's own config.
if ! git config --get extensions.worktreeConfig >/dev/null 2>&1; then
	if ! git config extensions.worktreeConfig true >/dev/null 2>&1; then
		echo "agent-git-setup.sh: ERROR: could not enable worktreeConfig extension" >&2
		echo "agent-git-setup.sh: the bot identity will leak into the main tree without it" >&2
		echo "agent-git-setup.sh: upgrade git to 2.43+ or enable the extension manually" >&2
		exit 1
	fi
	echo "agent-git-setup.sh: enabled worktreeConfig extension (per-worktree config isolation)"
fi

echo "agent-git-setup.sh: configuring worktree at $WT_PATH"

# IMPORTANT: a linked worktree shares the MAIN repo's config and remotes.
# "git -C $WT_PATH config" would resolve to the main repo and LEAK the bot
# identity into the human's tree. To truly isolate, we write to the worktree's
# OWN config file. On git 2.43+ with extensions.worktreeConfig enabled,
# git reads from config.worktree; otherwise from config.
if git config --get extensions.worktreeConfig >/dev/null 2>&1; then
	WT_CONFIG="$REPO_DIR/.git/worktrees/$WT_NAME/config.worktree"
else
	WT_CONFIG="$REPO_DIR/.git/worktrees/$WT_NAME/config"
fi
mkdir -p "$(dirname "$WT_CONFIG")"

# (1) Commit author — scoped to the worktree only (main tree untouched).
#     Agent name appears as author; email is bot noreply so agent shows in commit list.
git config -f "$WT_CONFIG" user.name "$AGENT_GIT_NAME"
git config -f "$WT_CONFIG" user.email "$COMMIT_EMAIL"

# (1b) Verify the worktree config is actually being read. Without
#      extensions.worktreeConfig (git 2.43+), git ignores the worktree config
#      file and the bot identity still leaks into the shared main config.
#      This check makes the failure loud instead of silent.
WT_USER_NAME=$(git -C "$WT_PATH" config user.name 2>/dev/null || true)
REPO_USER_NAME=$(git -C "$REPO_DIR" config user.name 2>/dev/null || true)
if [ "$WT_USER_NAME" != "$AGENT_GIT_NAME" ]; then
	echo "agent-git-setup.sh: ERROR: worktree did not pick up bot identity" >&2
	echo "agent-git-setup.sh: worktree user.name=$WT_USER_NAME (expected $AGENT_GIT_NAME)" >&2
	exit 1
fi
if [ "$REPO_USER_NAME" = "$AGENT_GIT_NAME" ]; then
	echo "agent-git-setup.sh: ERROR: bot identity leaked into the main tree" >&2
	echo "agent-git-setup.sh: main tree user.name=$REPO_USER_NAME (bot identity)" >&2
	exit 1
fi
echo "agent-git-setup.sh: isolation verified — main tree untouched"

# (2) Push actor is NOT configured here. Git worktrees share remotes, so we
#     do not rewrite origin (that would change the human's main tree). The bot
#     gh/API actor (PRs, issues, comments) is provided by GH_TOKEN in the
#     agent's environment, which drives gh/API calls as the bot. Plain
#     `git push` uses the repo's normal credential — the push actor is you.
#     credential — by design, so the main tree is never touched.

echo "agent-git-setup.sh: done. Agent should work in: $WT_PATH"
echo "  commits there are attributed to $AGENT_GIT_NAME <$COMMIT_EMAIL>"
echo "  your main tree at $REPO_DIR is untouched."
