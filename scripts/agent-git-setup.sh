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
#   repo's own .git/ directory does NOT match the glob, so it stays the account owner's.
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
# GitHub operations as the bot require `GH_TOKEN`; local commits do not.
#
# PREFLIGHT GUARDRAIL:
#   Run `--preflight --mode git-only` before local commits, or `--mode github`
#   before GitHub operations. Both require an actual linked worktree; GitHub mode
#   additionally checks trusted token-provider actor metadata and repository access. A harness lifecycle hook is needed
#   to guarantee preflight runs at the start of every session.
#
# Required environment variables:
#   AGENT_GIT_NAME    Commit author name, e.g. myagent[bot].
#   AGENT_GIT_BOT_ID  Numeric id of the bot account (optional online, required offline).
#   GH_TOKEN          Required only for GitHub-mode preflight and `gh`/API as the bot.
#   AGENT_GIT_TOKEN_ACTOR  Trusted actor login attested by the token provider; required in GitHub mode.
#
# Optional environment variables:
#   AGENT_GIT_SIGNINGKEY  DEPRECATED — SSH signing does not verify for bot
#                         noreply emails. Kept for backward compatibility
#                         but has no effect on bot identity commits.
#   AGENT_GIT_BOT_ID      Numeric bot id for the noreply email. If unset, the
#                         bot id is resolved via the public GitHub API.
#
# Usage:
#   agent-git-setup.sh --preflight --mode git-only|github [<repo-dir>]
#   agent-git-setup.sh <repo-dir>      # any worktree or the main repo of the repo
#   agent-git-setup.sh                 # operates on the cwd's repo

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument / mode handling
# ---------------------------------------------------------------------------

MODE="setup"
PREFLIGHT_MODE=""
if [ "${1:-}" = "--preflight" ]; then
	MODE="preflight"
	shift || true
fi

if [ "${1:-}" = "--mode" ]; then
	PREFLIGHT_MODE="${2:-}"
	shift 2
fi

if [ "$MODE" = "preflight" ] && [[ "$PREFLIGHT_MODE" != "git-only" && "$PREFLIGHT_MODE" != "github" ]]; then
	echo "agent-git-setup.sh: --preflight requires --mode git-only or --mode github" >&2
	exit 2
fi

# Operate on the repo the agent is in. A worktree or the main repo both resolve
# to the SAME shared .git, so we only need the toplevel. The includeIf we write
# then scopes the bot identity to all worktrees and excludes the main repo.
if [ -n "${1:-}" ]; then
	REPO_PATH="$(cd "$1" && pwd)"
else
	REPO_PATH="$(git rev-parse --show-toplevel)"
fi

# ---------------------------------------------------------------------------
# Preflight: fail-closed state checks (read-only, no worktree management)
# ---------------------------------------------------------------------------

preflight() {
	local ok=0

	# (1) Require a linked worktree, then validate effective author and
	# committer identities (including environment overrides), not just user.name.
	if [ -z "${AGENT_GIT_NAME:-}" ]; then
		echo "agent-git-setup.sh: PREFLIGHT FAIL: AGENT_GIT_NAME is unset." >&2
		echo "  Export AGENT_GIT_NAME (e.g. myagent[bot])." >&2
		ok=1
	else
		local git_dir common_dir resolved_name resolved_email author_ident committer_ident email_suffix
		git_dir="$(git -C "$REPO_PATH" rev-parse --absolute-git-dir 2>/dev/null || true)"
		common_dir="$(git -C "$REPO_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
		resolved_name="$(git -C "$REPO_PATH" config user.name 2>/dev/null || true)"
		resolved_email="$(git -C "$REPO_PATH" config user.email 2>/dev/null || true)"
		author_ident="$(git -C "$REPO_PATH" var GIT_AUTHOR_IDENT 2>/dev/null || true)"
		committer_ident="$(git -C "$REPO_PATH" var GIT_COMMITTER_IDENT 2>/dev/null || true)"
		email_suffix="${resolved_email#*+}"
		if [ -z "$git_dir" ] || [ -z "$common_dir" ] || [ "$git_dir" = "$common_dir" ]; then
			echo "agent-git-setup.sh: PREFLIGHT FAIL: target is not a linked worktree of the configured repo." >&2
			ok=1
		elif [ "$resolved_name" != "$AGENT_GIT_NAME" ] || [[ ! "$resolved_email" =~ ^[1-9][0-9]*\+ ]] || [ "$email_suffix" != "${AGENT_GIT_NAME}@users.noreply.github.com" ] || [[ "$author_ident" != "$AGENT_GIT_NAME <$resolved_email> "* ]] || [[ "$committer_ident" != "$AGENT_GIT_NAME <$resolved_email> "* ]]; then
			echo "agent-git-setup.sh: PREFLIGHT FAIL: bot author/committer identity is not effective at $REPO_PATH." >&2
			echo "  Expected $AGENT_GIT_NAME with its numeric GitHub noreply email; check local, worktree, and environment overrides." >&2
			ok=1
		fi
	fi

	if [ "$PREFLIGHT_MODE" = "github" ]; then
		if [ -z "${GH_TOKEN:-}" ] || [ -z "${AGENT_GIT_TOKEN_ACTOR:-}" ] || ! command -v gh >/dev/null 2>&1; then
			echo "agent-git-setup.sh: PREFLIGHT FAIL: github mode requires GH_TOKEN, AGENT_GIT_TOKEN_ACTOR, gh, and network access." >&2
			ok=1
		elif [[ "${AGENT_GIT_TOKEN_ACTOR,,}" != "${AGENT_GIT_NAME,,}" ]]; then
			echo "agent-git-setup.sh: PREFLIGHT FAIL: token provider actor '$AGENT_GIT_TOKEN_ACTOR' does not match '$AGENT_GIT_NAME'." >&2
			ok=1
		else
			local accessible_repo
			accessible_repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
			if [ -z "$accessible_repo" ]; then
				echo "agent-git-setup.sh: PREFLIGHT FAIL: GitHub token cannot access the current repository." >&2
				ok=1
			fi
		fi
	fi

	if [ "$ok" -ne 0 ]; then
		echo "agent-git-setup.sh: preflight aborted (fail-closed). Fix the above and re-run." >&2
		exit 1
	fi
	echo "agent-git-setup.sh: preflight OK — linked worktree identity verified ($PREFLIGHT_MODE mode)."
	exit 0
}

if [ "$MODE" = "preflight" ]; then
	preflight
fi

# ---------------------------------------------------------------------------
# Setup path (from here down: only runs in setup mode)
# ---------------------------------------------------------------------------

if [ ! -d "$REPO_PATH/.git" ] && [ ! -f "$REPO_PATH/.git" ]; then
	echo "agent-git-setup.sh: $REPO_PATH is not a git repository" >&2
	exit 2
fi

# The shared git directory (same for main and all its worktrees).
GIT_DIR="$(git -C "$REPO_PATH" rev-parse --absolute-git-dir)"
# If we are in a linked worktree, --absolute-git-dir points at
# <repo>/.git/worktrees/<name>; the shared dir is its parent's parent.
# Detect by path shape (a linked worktree's gitdir lives under .../.git/worktrees/<name>),
# NOT by the presence of config.worktree — that file only exists when
# extensions.worktreeConfig is enabled, which this design intentionally does not require.
if [ "$(basename "$(dirname "$GIT_DIR")")" = "worktrees" ]; then
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

# _RESOLVE_ID <handle>: print the numeric GitHub id for a handle, or empty.
# Uses the public API without GH_TOKEN; installation tokens cannot read arbitrary users.
# Written set -e-safe: a failed lookup is reported as unresolved and setup fails.
_RESOLVE_ID() {
	local _enc _id
	_enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1" 2>/dev/null || true)"
	_id="$(curl -sf -H "Accept: application/vnd.github+json" "https://api.github.com/users/${_enc}" 2>/dev/null |
		python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
	if [ -n "${_id:-}" ] && [ "${_id}" != "None" ]; then
		printf '%s' "$_id"
	fi
	return 0
}

# Commit email must resolve to the bot account. Never silently substitute the human identity.
# The bot id is numeric and determines GitHub's noreply account association.
if [ -n "${AGENT_GIT_BOT_ID:-}" ] && [[ ! "$AGENT_GIT_BOT_ID" =~ ^[1-9][0-9]*$ ]]; then
	echo "agent-git-setup.sh: AGENT_GIT_BOT_ID must be a positive integer without leading zeroes." >&2
	exit 2
fi
_COMMIT_EMAIL=""
if [ -n "${AGENT_GIT_BOT_ID:-}" ]; then
	_COMMIT_EMAIL="${AGENT_GIT_BOT_ID}+${AGENT_GIT_NAME}@users.noreply.github.com"
else
	_BID="$(_RESOLVE_ID "$AGENT_GIT_NAME")"
	if [ -n "${_BID:-}" ]; then
		_COMMIT_EMAIL="${_BID}+${AGENT_GIT_NAME}@users.noreply.github.com"
	fi
fi

if [ -z "${_COMMIT_EMAIL:-}" ]; then
	echo "agent-git-setup.sh: could not resolve the bot account id. Provide numeric AGENT_GIT_BOT_ID or network access to the public GitHub user API." >&2
	exit 1
fi
COMMIT_EMAIL="$_COMMIT_EMAIL"

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
# Verify: main stays the account owner's, worktrees become bot
# ---------------------------------------------------------------------------

# Main repo must remain the account owner's (the glob excludes its .git directory).
# Read the shared .git directly via --git-dir so this check is correct even when
# REPO_PATH is a worktree (querying the worktree path would return the bot identity
# that includeIf applies to worktrees, giving a false "leaked" failure).
MAIN_USER_NAME="$(git --git-dir="$GIT_DIR" config user.name 2>/dev/null || true)"
if [ "$MAIN_USER_NAME" = "$AGENT_GIT_NAME" ]; then
	echo "agent-git-setup.sh: ERROR: bot identity leaked into the main repo" >&2
	exit 1
fi

# A worktree must read as the bot. If we are currently inside a linked
# worktree, verify it directly. Otherwise, if any linked worktree exists,
# verify the first one. (The includeIf entry itself is already verified
# present above; this confirms it is actually honoured.)
CURRENT_GITDIR="$(git -C "$REPO_PATH" rev-parse --absolute-git-dir)"
# Detect "currently inside a linked worktree" by path shape, not config.worktree
# (see GIT_DIR resolution above for why).
if [ "$(basename "$(dirname "$CURRENT_GITDIR")")" = "worktrees" ]; then
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

# Push actor: this script does NOT configure push. The agent opens PRs as the
# bot via `gh` + GH_TOKEN in its environment. Plain `git push` still uses the
# repo's normal credential by default; that is harness/push-mechanism territory,
# not this script's. The bot API actor (PRs, issues, comments, API commits for
# the Verified badge) is provided by GH_TOKEN.

echo "agent-git-setup.sh: done. All worktrees in: $REPO_PATH"
echo "  author = $AGENT_GIT_NAME <$COMMIT_EMAIL>"
echo "  PR/API actor = bot via GH_TOKEN (agent opens PRs as the bot)"
