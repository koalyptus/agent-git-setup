#!/usr/bin/env bash
#
# agent-git-setup.sh
#
# Give an AI agent its own git identity — commit author = <name>[bot].
#
# This script is IDENTITY-ONLY. It does NOT create worktrees, does NOT manage
# hooks, does NOT rewrite remotes, and does NOT impose a path or branch
# convention. Worktree lifecycle, hooks, and branching are the agent harness's
# responsibility. The harness places the agent in a worktree; this script only
# writes the bot commit identity into that worktree's OWN config.
#
# This script is completely backend/agent-neutral. It does NOT mint tokens and
# contains no secrets. It expects the desired bot identity in the environment,
# then writes it to the worktree-local git config so commits are authored as
# that bot identity — while your main checkout stays exactly as you.
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
# The harness owns worktree creation. This script needs ONE thing from it:
#   git 2.43+ `extensions.worktreeConfig` must be enabled in the MAIN repo so
#   that per-worktree config (user.*) is actually read and does NOT leak into
#   the shared main config. Enabling it writes to the main repo config, so we
#   never do it silently. If it is missing, we ERROR and tell the AGENT to ASK
#   THE HUMAN whether they may enable it (one command:
#   `git config extensions.worktreeConfig true` in the main repo).
#
# IDENTITY MODEL (no "human PR" convention):
#   - Commit author: always the bot (local `git commit` in the worktree).
#   - PR / API actor: the bot too, via `GH_TOKEN` + `gh` in the agent's
#     environment. The agent opens PRs as the bot. `GH_TOKEN` is therefore
#     MANDATORY in the agent flow — it is no longer optional prose.
#   - Local `git push` still uses the repo's normal credential by default; the
#     bot opens the PR via `gh` (GH_TOKEN), not via a rewritten origin. This
#     script never rewrites `origin` (worktrees share remotes).
#   - No Verified badge: that needs API-created commits, not a local commit
#     pushed via `git push`. Out of scope by design.
#
# PREFLOW GUARDRAIL:
#   Run `agent-git-setup.sh --preflight` before ANY git/gh work. It fails
#   non-zero (fail-closed) if the agent is in the MAIN tree (commits there
#   would be attributed to YOU, the human) or if `GH_TOKEN` is missing (no bot
#   PR/API actor). This converts the most common mis-attribution failure — an
#   agent committing from the main tree as the human — from prose into a
#   hard mechanism, without the script ever creating or demanding a worktree.
#   `--preflight` reads state only; it does not manage worktrees or hooks.
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
# Mandatory environment variables (agent flow):
#   GH_TOKEN          A GitHub token (e.g. an App install token) for
#                     `gh`/API operations AS THE BOT (PRs, issues,
#                     comments, and API commits for Verified badge). The agent
#                     opens PRs as the bot, so this is required in the agent
#                     flow. `--preflight` fails closed if it is missing.
#
# Optional environment variables:
#   AGENT_GIT_SIGNINGKEY  DEPRECATED — SSH signing does not verify for bot
#                         noreply emails. Kept for backward compatibility
#                         but has no effect on bot identity commits.
#   AGENT_GIT_BOT_ID      Hidden override: the numeric bot id for the noreply
#                         email. Used for hermetic tests / offline use (no
#                         network). If unset, the bot id is resolved via the
#                         public GitHub API.
#
# Usage:
#   agent-git-setup.sh --preflight [<worktree-dir>]
#   agent-git-setup.sh [<worktree-dir>]
#   agent-git-setup.sh            # operates on the cwd's worktree toplevel

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument / mode handling
# ---------------------------------------------------------------------------

MODE="setup"
if [ "${1:-}" = "--preflight" ]; then
	MODE="preflight"
	shift || true
fi

# Operate on the worktree the harness already created. Default to cwd's
# toplevel so a harness that already cd'd the agent into the worktree can just
# run the script with no argument.
if [ -n "${1:-}" ]; then
	WT_PATH="$(cd "$1" && pwd)"
else
	WT_PATH="$(git rev-parse --show-toplevel)"
fi

# ---------------------------------------------------------------------------
# Preflight: fail-closed state checks (read-only, no worktree management)
# ---------------------------------------------------------------------------

preflight() {
	local ok=0

	# (1) Are we in a worktree, or the main tree?
	if [ ! -d "$WT_PATH/.git" ] && [ ! -f "$WT_PATH/.git" ]; then
		echo "agent-git-setup.sh: PREFLOW FAIL: $WT_PATH is not a git worktree." >&2
		echo "  No worktree present -> any commit made here is attributed to YOU (human)." >&2
		ok=1
	else
		local wt_gitdir
		wt_gitdir="$(git -C "$WT_PATH" rev-parse --absolute-git-dir 2>/dev/null || true)"
		if [ "$(basename "$wt_gitdir")" = ".git" ]; then
			echo "agent-git-setup.sh: PREFLOW FAIL: $WT_PATH is the MAIN repo, not a worktree." >&2
			echo "  No worktree present -> commits made here are attributed to YOU (human)." >&2
			echo "  Ask the harness/agent to place you in the agent worktree it created, then re-run." >&2
			ok=1
		fi
	fi

	# (2) GH_TOKEN mandatory in the agent flow (bot PRs/API). Fail closed.
	if [ -z "${GH_TOKEN:-}" ]; then
		echo "agent-git-setup.sh: PREFLOW FAIL: GH_TOKEN is unset." >&2
		echo "  The agent opens PRs / acts on GitHub AS THE BOT, so a token is required." >&2
		echo "  Mint one (scripts/mint-token.sh) and export GH_TOKEN before any git/gh work." >&2
		ok=1
	fi

	if [ "$ok" -ne 0 ]; then
		echo "agent-git-setup.sh: preflight aborted (fail-closed). Fix the above and re-run." >&2
		exit 1
	fi
	echo "agent-git-setup.sh: preflight OK — in a worktree, GH_TOKEN present."
	exit 0
}

if [ "$MODE" = "preflight" ]; then
	preflight
fi

# ---------------------------------------------------------------------------
# Setup path (from here down: only runs in setup mode)
# ---------------------------------------------------------------------------

if [ ! -d "$WT_PATH/.git" ] && [ ! -f "$WT_PATH/.git" ]; then
	echo "agent-git-setup.sh: $WT_PATH is not a git worktree" >&2
	exit 2
fi

# The main repo is the worktree's parent git dir. We need it to (a) find the
# worktree-local config file and (b) check the worktreeConfig extension.
# git-common-dir from a linked worktree points at the MAIN repo's .git; it may
# be relative, so resolve it absolutely against the worktree.
COMMON_DIR="$(git -C "$WT_PATH" rev-parse --path-format=absolute --git-common-dir)"
REPO_DIR="$(dirname "$COMMON_DIR")"

# ---------------------------------------------------------------------------
# Required environment
# ---------------------------------------------------------------------------

: "${AGENT_GIT_NAME:?set AGENT_GIT_NAME, e.g. myagent[bot]}"
: "${GH_TOKEN:?set GH_TOKEN (bot token for gh/API -- the agent opens PRs as the bot)}"

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
		_GIT_UID="$(curl -sf -H "Authorization: Bearer ***" -H "Accept: application/vnd.github.v3+json" "https://api.github.com/users/$GIT_USER_NAME" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
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
# Require the harness to have enabled worktreeConfig — we will NOT write it.
# ---------------------------------------------------------------------------

# Without extensions.worktreeConfig (git 2.43+), per-worktree config is ignored
# and the bot identity leaks into the shared main config. We never enable it
# silently because that writes to the human's main repo. If the harness did not
# enable it, ERROR and tell the AGENT to ASK THE HUMAN for permission.
if ! git -C "$WT_PATH" config --get extensions.worktreeConfig >/dev/null 2>&1; then
	echo "agent-git-setup.sh: ERROR: git 2.43+ 'extensions.worktreeConfig' is NOT enabled." >&2
	echo "agent-git-setup.sh: without it, the bot identity would leak into the shared main config." >&2
	echo "agent-git-setup.sh: ASK THE HUMAN whether you may enable it in the main repo:" >&2
	echo "    git -C \"$REPO_DIR\" config extensions.worktreeConfig true" >&2
	echo "agent-git-setup.sh: this writes one line to the main repo's config (one-time). Re-run after." >&2
	exit 1
fi

# Worktree-local config file. With the extension enabled, git reads config.worktree.
WT_NAME="$(basename "$(git -C "$WT_PATH" rev-parse --absolute-git-dir)")"
if [ "$WT_NAME" = ".git" ]; then
	# Not a linked worktree (cwd IS the main repo) — refuse to write main config.
	echo "agent-git-setup.sh: ERROR: $WT_PATH is the MAIN repo, not a worktree." >&2
	echo "agent-git-setup.sh: running here would attribute commits to YOU (human), not the bot." >&2
	echo "agent-git-setup.sh: ask the harness/agent to place you in the agent worktree it created." >&2
	exit 1
fi
WT_CONFIG="$REPO_DIR/.git/worktrees/$WT_NAME/config.worktree"
mkdir -p "$(dirname "$WT_CONFIG")"

# (1) Commit author — scoped to the worktree only (main tree untouched).
#     Agent name appears as author; email is bot noreply so agent shows in commit list.
git config -f "$WT_CONFIG" user.name "$AGENT_GIT_NAME"
git config -f "$WT_CONFIG" user.email "$COMMIT_EMAIL"

# (2) Verify the worktree config is actually being read. If the extension is
#     somehow not honoured, the bot identity would leak into the main config.
#     This check makes the failure loud instead of silent.
WT_USER_NAME="$(git -C "$WT_PATH" config user.name 2>/dev/null || true)"
REPO_USER_NAME="$(git -C "$REPO_DIR" config user.name 2>/dev/null || true)"
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

# (3) Push actor: this script does NOT configure push. The agent opens PRs as
#     the bot via `gh` + GH_TOKEN in its environment. Local `git push` still
#     uses the repo's normal credential by default; that is harness/push
#     mechanism territory, not this script's. The bot API actor (PRs, issues,
#     comments, API commits for the Verified badge) is provided by GH_TOKEN.

echo "agent-git-setup.sh: done. Agent commits in: $WT_PATH"
echo "  author = $AGENT_GIT_NAME <$COMMIT_EMAIL>"
echo "  PR/API actor = bot via GH_TOKEN (agent opens PRs as the bot)"
