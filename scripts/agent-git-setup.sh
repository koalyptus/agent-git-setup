#!/usr/bin/env bash
#
# agent-git-setup.sh
#
# Give an AI agent its own git identity — commit author = <name>[bot].
#
# This script is IDENTITY-ONLY. It does NOT create worktrees, does NOT manage
# hooks, does NOT rewrite remotes, and does NOT impose a path or branch
# convention. Worktree lifecycle, hooks, and branching are the agent harness's
# responsibility.
#
# ONE-OFF PER REPO, ALL WORKTREES:
#   Instead of configuring each worktree separately, this script writes the bot
#   identity ONCE to the shared repo config using git's conditional-include
#   feature (`includeIf "gitdir/i:**/.git/worktrees/**"`). Every linked worktree
#   lives under .git/worktrees/<name>, so they all inherit the bot identity
#   automatically — including worktrees created AFTER this script runs. The main
#   repo's own .git/ directory does NOT match the glob, so it stays human.
#
#   This means: run the script once per repo/clone, and every agent worktree
#   (present and future, including subagent-delegated ones) commits as the bot,
#   while your main checkout and global git config are never touched.
#
# This script is completely backend/agent-neutral. It does NOT mint tokens and
# contains no secrets. It expects the desired bot identity in the environment,
# then writes it to repo-local git config so commits are authored as that bot
# identity — while your main checkout stays exactly as you.
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
#   AGENT_GIT_BOT_ID      Hidden override: the numeric bot id for the noreply
#                         email. Used for hermetic tests / offline use (no
#                         network). If unset, the bot id is resolved via the
#                         public GitHub API.
#
# Usage:
#   agent-git-setup.sh <repo-dir>      # any worktree or the main repo of the repo
#   agent-git-setup.sh                 # operates on the cwd's repo

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

# Operate on the repo the agent is in. A worktree or the main repo both resolve
# to the SAME shared .git, so we only need the toplevel. The includeIf we write
# then scopes the bot identity to all worktrees and excludes the main repo.
if [ -n "${1:-}" ]; then
	REPO_PATH="$(cd "$1" && pwd)"
else
	REPO_PATH="$(git rev-parse --show-toplevel)"
fi

if [ ! -d "$REPO_PATH/.git" ] && [ ! -f "$REPO_PATH/.git" ]; then
	echo "agent-git-setup.sh: $REPO_PATH is not a git repository" >&2
	exit 2
fi

# The shared git directory (same for main and all its worktrees).
GIT_DIR="$(git -C "$REPO_PATH" rev-parse --absolute-git-dir)"
# If we are in a linked worktree, --absolute-git-dir points at
# <repo>/.git/worktrees/<name>; the shared dir is its parent's parent.
if [ -f "$GIT_DIR"/config.worktree ]; then
	GIT_DIR="$(dirname "$(dirname "$GIT_DIR")")"
fi
# GIT_DIR should now be <repo>/.git
if [ "$(basename "$GIT_DIR")" != ".git" ]; then
	echo "agent-git-setup.sh: could not locate the shared .git directory (got $GIT_DIR)" >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# Hardening guards (deterministic, fail-closed)
# ---------------------------------------------------------------------------

# Resolve the directory this script lives in (symlink-resolved absolute path).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Guard A — self-nesting: this tool must never be run from inside the repo it is
# meant to configure. agent-git-setup must be cloned OUTSIDE the target repo
# (e.g. /tmp/agent-git-setup); otherwise we would write identity config into a
# repo that contains the tool itself. Refuse loudly.
case "$SCRIPT_DIR" in
"$REPO_PATH" | "$REPO_PATH"/*)
	echo "agent-git-setup.sh: ERROR: this script lives inside the target repo ($SCRIPT_DIR)." >&2
	echo "agent-git-setup.sh: clone agent-git-setup OUTSIDE the repo (e.g. /tmp) and run from there." >&2
	exit 2
	;;
esac

# Guard B — stable location: the bot config is written at $GIT_DIR/agent-bot-identity.config
# and the includeIf points at that absolute path. If the repo's .git lives under an
# ephemeral tree (/tmp, $TMPDIR, /dev/shm), that path is deleted when the session ends,
# leaving a dangling includeIf in the repo. Refuse in production; the test harness opts
# in with AGENT_GIT_ALLOW_TMP=1 (its repos are intentionally throwaway).
case "$GIT_DIR" in
/tmp/* | "${TMPDIR:-/nonexistent}"/* | /dev/shm/*)
	if [ -z "${AGENT_GIT_ALLOW_TMP:-}" ]; then
		echo "agent-git-setup.sh: ERROR: target repo's .git is in an ephemeral location ($GIT_DIR)." >&2
		echo "agent-git-setup.sh: configure a persistent repo, not an ephemeral one." >&2
		exit 2
	fi
	;;
esac

# Guard C — anti-bloat key: we always write this single, fixed includeIf key, so
# re-runs overwrite in place and can never accumulate duplicates. Defined here so
# the post-write assertion (below) and the write share one source of truth.
INCLUDE_KEY="includeIf.gitdir/i:**/.git/worktrees/**.path"

# ---------------------------------------------------------------------------
# Required environment
# ---------------------------------------------------------------------------

: "${AGENT_GIT_NAME:?set AGENT_GIT_NAME, e.g. myagent[bot]}"

# GIT_USER_NAME (handle) is the human-facing input. GIT_USER_ID is a hidden
# fallback for hermetic tests / offline use. If only the handle is set, resolve
# it via the public GitHub API (GET /users/<handle> is unauthenticated);
# when GH_TOKEN is set, use it as Bearer for higher rate limits / private.
# Validate the handle shape before interpolating into the URL (GitHub handles
# are [A-Za-z0-9-] only — reject anything else to avoid malformed requests).
_VALIDATE_HANDLE() {
	case "$1" in
	*[!A-Za-z0-9-]*) return 1 ;;
	*) return 0 ;;
	esac
}
if [ -n "${GIT_USER_ID:-}" ]; then
	_GIT_UID="$GIT_USER_ID"
elif [ -n "${GIT_USER_NAME:-}" ]; then
	if ! _VALIDATE_HANDLE "$GIT_USER_NAME"; then
		echo "agent-git-setup.sh: GIT_USER_NAME must be a GitHub handle ([A-Za-z0-9-] only), got: $GIT_USER_NAME" >&2
		exit 2
	fi
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
elif [ -n "${GIT_USER_NAME:-}" ]; then
	COMMIT_EMAIL="${GIT_USER_ID}+${GIT_USER_NAME}@users.noreply.github.com"
else
	COMMIT_EMAIL="${GIT_USER_ID}+${AGENT_GIT_NAME}@users.noreply.github.com"
fi

# ---------------------------------------------------------------------------
# Write the bot identity ONCE, scoped to all worktrees via includeIf
# ---------------------------------------------------------------------------

# The included config file holds the bot identity. It lives inside .git/ so it
# is never committed and stays per-clone/per-machine. Written with `git config -f`
# (quoted args) so AGENT_GIT_NAME / COMMIT_EMAIL are stored verbatim — no shell
# expansion, command substitution, or config-section breakout is possible even if
# those values contain $(...), backticks, or newlines.
BOT_CONFIG="$GIT_DIR/agent-bot-identity.config"
git config -f "$BOT_CONFIG" user.name "$AGENT_GIT_NAME"
git config -f "$BOT_CONFIG" user.email "$COMMIT_EMAIL"

# Conditional include: apply the bot config to every linked worktree
# (.git/worktrees/<name>) but NOT to the main repo's own .git directory.
# This makes the setup one-off for the whole repo, including future worktrees.
git -C "$REPO_PATH" config --local "$INCLUDE_KEY" "$BOT_CONFIG"

# Guard C (assert) — anti-bloat: exactly one includeIf entry must now exist.
# Deterministic guarantee that re-runs cannot accumulate duplicates.
_cfg_count="$(git -C "$REPO_PATH" config --local --get-all "$INCLUDE_KEY" 2>/dev/null | wc -l)"
_cfg_count="${_cfg_count//[[:space:]]/}"
if [ "${_cfg_count:-0}" -ne 1 ]; then
	echo "agent-git-setup.sh: ERROR: expected exactly one includeIf entry, found ${_cfg_count:-0} (config bloat)." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Verify: main stays human, worktrees become bot
# ---------------------------------------------------------------------------

# Main repo must remain human (the glob excludes its .git directory).
MAIN_USER_NAME="$(git -C "$REPO_PATH" config user.name 2>/dev/null || true)"
if [ "$MAIN_USER_NAME" = "$AGENT_GIT_NAME" ]; then
	echo "agent-git-setup.sh: ERROR: bot identity leaked into the main repo" >&2
	exit 1
fi

# A worktree must read as the bot. If we are currently inside a linked
# worktree, verify it directly. Otherwise, if any linked worktree exists,
# verify the first one. (The includeIf entry itself is already verified
# present above; this confirms it is actually honoured.)
CURRENT_GITDIR="$(git -C "$REPO_PATH" rev-parse --absolute-git-dir)"
if [ -f "$CURRENT_GITDIR/config.worktree" ]; then
	WT_TEST="$REPO_PATH"
else
	# Pick the first linked worktree (skip the main worktree line).
	WT_TEST="$(git -C "$REPO_PATH" worktree list --porcelain |
		awk '/^worktree /{print $2}' | grep -vF "$REPO_PATH" | head -1 || true)"
fi
if [ -n "${WT_TEST:-}" ] && [ -d "$WT_TEST/.git" ]; then
	WT_USER_NAME="$(git -C "$WT_TEST" config user.name 2>/dev/null || true)"
	if [ "$WT_USER_NAME" != "$AGENT_GIT_NAME" ]; then
		echo "agent-git-setup.sh: ERROR: worktree did not pick up bot identity (got '$WT_USER_NAME')" >&2
		exit 1
	fi
fi

echo "agent-git-setup.sh: isolation verified — main tree untouched, all worktrees bot"
echo "agent-git-setup.sh: one-off setup; future worktrees inherit bot identity automatically"

# Push actor is NOT configured here. Plain `git push` uses the human's
# credential — the push actor is the human, by design. Pushing and opening
# PRs are HUMAN actions; this script only sets commit AUTHOR identity.
# The bot gh/API actor (PRs, issues, comments) is provided by GH_TOKEN in
# the agent's environment, which drives gh/API calls as the bot.

echo "agent-git-setup.sh: done. All worktrees in: $REPO_PATH"
echo "  author = $AGENT_GIT_NAME <$COMMIT_EMAIL>"
echo "  push actor = human (design); gh/API actor = bot via GH_TOKEN"
