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
# The agent opens PRs / acts on GitHub AS THE BOT via `gh` + `GH_TOKEN` in its
# environment (PRs, issues, comments, API commits for the Verified badge). So
# `GH_TOKEN` is mandatory in the agent flow. `--preflight` (below) fails closed
# if it is missing — rather than silently falling back to the account owner's `gh auth`.
#
# PREFLOW GUARDRAIL:
#   Run `agent-git-setup.sh --preflight` BEFORE any git/gh work. It fails
#   non-zero (fail-closed) if the agent is in the MAIN repo (commits there would
#   be attributed to YOU, the account owner — the includeIf glob excludes the main
#   tree's .git, so a main-tree commit is attributed to the account owner) or if `GH_TOKEN` is missing (no
#   bot PR/API actor). This converts the most common mis-attribution failure —
#   an agent committing from the main tree as the account owner — from documentation
#   into a hard mechanism, without the script ever creating or demanding a
#   worktree. `--preflight` reads state only; it does not manage worktrees or
#   hooks.
#
# Required environment variables:
#   AGENT_GIT_NAME    Commit author name, e.g. myagent[bot].
#   GIT_USER_NAME     GitHub handle (e.g. my-git-user-name). LAST-RESORT fallback
#                     only: if the bot id cannot be resolved, commits are attributed
#                     to this account-owner handle (id via GIT_USER_ID or the API). Prefer
#                     AGENT_GIT_BOT_ID / AGENT_GIT_NAME so commits stay bot.
#   GIT_USER_ID       Numeric GitHub user id (alternative to GIT_USER_NAME).
#                     If set, used directly as the fallback noreply prefix.
#                     Otherwise the script fetches the id via the public API.
#
# Mandatory environment variables (agent flow):
#   GH_TOKEN              A GitHub token (e.g. an App install token) for
#                         `gh`/API operations AS THE BOT (PRs, issues,
#                         comments, and API commits for Verified badge). The
#                         agent opens PRs as the bot, so this is required in the
#                         agent flow. `--preflight` fails closed if it is missing.
#
# Optional environment variables:
#   AGENT_GIT_SIGNINGKEY  DEPRECATED — SSH signing does not verify for bot
#                         noreply emails. Kept for backward compatibility
#                         but has no effect on bot identity commits.
#   AGENT_GIT_BOT_ID      Hidden override: the numeric bot id for the noreply
#                         email. Used for hermetic tests / offline use (no
#                         network). If unset, the bot id is resolved via the
#                         public GitHub API (uses GH_TOKEN as Bearer if set).
#
# Usage:
#   agent-git-setup.sh --preflight [<repo-dir>]
#   agent-git-setup.sh <repo-dir>      # any worktree or the main repo of the repo
#   agent-git-setup.sh                 # operates on the cwd's repo

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument / mode handling
# ---------------------------------------------------------------------------

MODE="setup"
if [ "${1:-}" = "--preflight" ]; then
	MODE="preflight"
	shift || true
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

	# (1) Is the bot commit identity actually IN EFFECT here? This is the real
	# guard, and it is deliberately location-agnostic: we do NOT check where the
	# worktree lives on disk. We check the EFFECT — that git resolves the commit
	# author identity to AGENT_GIT_NAME for this repo. The bot identity is applied
	# by the includeIf the setup script wrote into the target repo's .git/config
	# (gitdir/i:**/.git/worktrees/**), which fires for any LINKED WORKTREE of that
	# repo regardless of where the harness placed it. A main-repo checkout, a
	# detached checkout, or a separate clone (even under ~/.agent-git-setup) will
	# NOT resolve to AGENT_GIT_NAME, so this fails closed instead of silently
	# committing as the account owner.
	if [ -z "${AGENT_GIT_NAME:-}" ]; then
		echo "agent-git-setup.sh: PREFLOW FAIL: AGENT_GIT_NAME is unset." >&2
		echo "  The bot commit identity cannot be verified without it. Export AGENT_GIT_NAME (e.g. myagent[bot])." >&2
		ok=1
	else
		local resolved
		resolved="$(git -C "$REPO_PATH" config user.name 2>/dev/null || true)"
		if [ "$resolved" != "$AGENT_GIT_NAME" ]; then
			echo "agent-git-setup.sh: PREFLOW FAIL: bot identity not in effect at $REPO_PATH." >&2
			echo "  Resolved user.name='${resolved:-<empty>}' but expected '$AGENT_GIT_NAME'." >&2
			echo "  You are not in a linked worktree of the target repo where the bot identity" >&2
			echo "  applies (main checkout, detached checkout, or a separate clone all fail this)." >&2
			echo "  Run 'scripts/agent-git-setup.sh <repo-dir>' from a proper 'git worktree' of the" >&2
			echo "  target repo, then re-run. Location is irrelevant — only that the bot identity resolves." >&2
			ok=1
		fi
	fi

	# (2) GH_TOKEN mandatory in the agent flow, AND it must be the BOT actor.
	# Presence is not enough: a token minted from the account owner's own PAT
	# (the ambient `gh auth` login) passes the "is it set?" test yet makes every
	# `gh`/API call land under the ACCOUNT OWNER (the exact bug this guard exists
	# to stop). So we verify the EFFECTIVE actor, not just that a token exists.
	if [ -z "${GH_TOKEN:-}" ]; then
		echo "agent-git-setup.sh: PREFLOW FAIL: GH_TOKEN is unset." >&2
		echo "  The agent opens PRs / acts on GitHub AS THE BOT, so a token is required." >&2
		echo "  Mint one (scripts/mint-token.sh) and export GH_TOKEN before any git/gh work." >&2
		ok=1
	else
		# Probe the effective GitHub actor via `gh api user`. This needs `gh`
		# and network; if either is unavailable we CANNOT verify identity, so we
		# degrade to a warning (not a hard fail) — hermetic/offline environments
		# (e.g. the test suite, air-gapped hosts) legitimately have no `gh`. The
		# trade-off is documented: when `gh`/network is absent we cannot stop a
		# your-PAT fallback, so the agent MUST still mint the bot token from
		# the credentials file as the documented happy path.
		local actor_type actor_login gh_rc
		if command -v gh >/dev/null 2>&1; then
			# The account owner's PAT can read `gh api user` (200, type "User").
			# A GitHub App INSTALLATION token cannot (it returns 403 —
			# installation tokens are not user-authenticated). That 403 IS the
			# bot signal. `gh api /app` is unusable here (it needs the App JWT,
			# not the install token). So:
			#   - `gh api user` -> type "User"  => ACCOUNT OWNER (fail unless consented)
			#   - `gh api user` -> non-zero (403) => BOT install token (pass)
			#   - anything else (network down)    => cannot verify (warn)
			local who
			# NOTE: under `set -e`, a failed command substitution aborts the
			# script. A bot install token makes `gh api user` exit 1 (403), so we
			# MUST guard it: append `|| true` and read the real exit code from the
			# assignment (not from the substitution directly).
			who="$(gh api user --jq '{type: .type, login: .login}' 2>/dev/null || true)"
			gh_rc=$?
			if [ "$gh_rc" -eq 0 ]; then
				actor_type="$(printf '%s' "$who" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')"
				actor_login="$(printf '%s' "$who" | sed -n 's/.*"login":"\([^"]*\)".*/\1/p')"
			fi
		fi
		if [ "${actor_type:-}" = "User" ]; then
			# Token resolves to the ACCOUNT OWNER (User) account, not the bot.
			# This is the fail-closed case. The agent MUST NOT proceed and MUST
			# NOT silently fall back to the account owner. Instead it stops and
			# asks the account owner for explicit consent (out of band — e.g. in
			# the chat). On that explicit "yes", the AGENT sets
			# AGENT_GIT_ALLOW_HUMAN_ACTOR=1 for that session and re-runs
			# preflight; the account owner never types the flag by hand. There is
			# NO default and no silent fallback. Running as the account owner is
			# only ever the agent's record of your approved consent.
			if [ "${AGENT_GIT_ALLOW_HUMAN_ACTOR:-}" = "1" ]; then
				echo "agent-git-setup.sh: PREFLOW WARN: proceeding as the ACCOUNT OWNER '$actor_login' — AGENT_GIT_ALLOW_HUMAN_ACTOR=1 was set by the agent after your explicit consent." >&2
				echo "  gh/API calls will be attributed to YOU, not the bot. This is the last-resort fallback you approved." >&2
			else
				echo "agent-git-setup.sh: PREFLOW FAIL: GH_TOKEN resolves to the ACCOUNT OWNER '$actor_login', not the bot." >&2
				echo "  gh/API calls would be attributed to YOU, not the bot. The ambient gh auth" >&2
				echo "  login is your PAT — that is NOT the agent identity." >&2
				echo "  Preferred fix: mint the bot token and export it before any gh/API work:" >&2
				echo "    source <(scripts/mint-token.sh --shell)   # writes GH_TOKEN from the App creds" >&2
				echo "  Only if that genuinely fails (creds gone / App revoked) AND you explicitly approve," >&2
				echo "  tell the agent to proceed as you. The agent then sets AGENT_GIT_ALLOW_HUMAN_ACTOR=1" >&2
				echo "  for this session and re-runs preflight — you do NOT export it yourself." >&2
				ok=1
			fi
		elif [ -z "${actor_type:-}" ]; then
			# `gh api user` failed for any other reason (403 = bot install token,
			# or network/gh unavailable). 403 from a real App install token is the
			# EXPECTED bot case; we cannot distinguish it from "no network" here,
			# so we treat the absence of a confirmed account owner as pass (do not
			# block a valid bot token). If gh is genuinely absent, we warn instead.
			if command -v gh >/dev/null 2>&1; then
				: # bot install token (403) or unreadable — do not block
			else
				echo "agent-git-setup.sh: PREFLOW WARN: could not verify GH_TOKEN actor (gh not installed / network unavailable)." >&2
				echo "  Cannot confirm the token is the App bot — if it is your PAT, gh/API" >&2
				echo "  calls will be attributed to YOU. Mint the bot token (scripts/mint-token.sh" >&2
				echo "  --shell) and ensure gh + network before any gh/API work." >&2
			fi
		else
			# Resolved to something other than "User" (e.g. "Bot" for a true
			# user-account bot) — not your PAT, allow.
			: # not the account-owner actor — pass
		fi
	fi

	if [ "$ok" -ne 0 ]; then
		echo "agent-git-setup.sh: preflight aborted (fail-closed). Fix the above and re-run." >&2
		exit 1
	fi
	echo "agent-git-setup.sh: preflight OK — bot identity in effect, GH_TOKEN present."
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

# GIT_USER_NAME (optional, account-owner-facing handle) is validated for shape and, ONLY
# as a LAST-RESORT fallback when the bot id cannot be resolved, used to attribute
# commits to the account owner. The primary bot identity always comes from the bot's own
# numeric id; the account-owner handle is never preferred over it.
_VALIDATE_HANDLE() {
	case "$1" in
	*[!A-Za-z0-9-]*) return 1 ;;
	*) return 0 ;;
	esac
}
if [ -n "${GIT_USER_NAME:-}" ] && ! _VALIDATE_HANDLE "$GIT_USER_NAME"; then
	echo "agent-git-setup.sh: GIT_USER_NAME must be a GitHub handle ([A-Za-z0-9-] only), got: $GIT_USER_NAME" >&2
	exit 2
fi

# _RESOLVE_ID <handle>: print the numeric GitHub id for a handle, or empty.
# Uses the public API; sends GH_TOKEN as Bearer when set (higher rate limit /
# private visibility). Network or rate-limit failures yield empty -> caller falls back.
# Written set -e-safe: a failed lookup must never abort the script (we fall back).
_RESOLVE_ID() {
	local _enc _id _auth=()
	_enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1" 2>/dev/null || true)"
	if [ -n "${GH_TOKEN:-}" ]; then
		_auth=(-H "Authorization: Bearer ${GH_TOKEN}")
	fi
	_id="$(curl -sf "${_auth[@]}" -H "Accept: application/vnd.github.v3+json" "https://api.github.com/users/${_enc}" 2>/dev/null |
		python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
	if [ -n "${_id:-}" ] && [ "${_id}" != "None" ]; then
		printf '%s' "$_id"
	fi
	return 0
}

# Commit email: prefer the BOT's own noreply identity so commits show as the agent.
# Resolution order (bot-first, account-owner-fallback-last; fail only if nothing resolves):
#   1. AGENT_GIT_BOT_ID   -> <id>+<AGENT_GIT_NAME>@users.noreply.github.com   (offline-safe)
#   2. AGENT_GIT_NAME     -> API-resolved bot id (uses GH_TOKEN as Bearer if set)
#   3. GIT_USER_NAME      -> account-owner-attributed fallback (a setup that succeeds as
#                            the account owner beats a failed setup). id = GIT_USER_ID, or the
#                            API-resolved id of the handle.
_COMMIT_EMAIL=""
if [ -n "${AGENT_GIT_BOT_ID:-}" ]; then
	_COMMIT_EMAIL="${AGENT_GIT_BOT_ID}+${AGENT_GIT_NAME}@users.noreply.github.com"
else
	_BID="$(_RESOLVE_ID "$AGENT_GIT_NAME")"
	if [ -n "${_BID:-}" ]; then
		_COMMIT_EMAIL="${_BID}+${AGENT_GIT_NAME}@users.noreply.github.com"
	fi
fi

# Last resort: account-owner-attributed identity (only when the bot id could not be resolved).
if [ -z "${_COMMIT_EMAIL:-}" ] && [ -n "${GIT_USER_NAME:-}" ]; then
	if [ -n "${GIT_USER_ID:-}" ]; then
		_COMMIT_EMAIL="${GIT_USER_ID}+${GIT_USER_NAME}@users.noreply.github.com"
	else
		_UID="$(_RESOLVE_ID "$GIT_USER_NAME")"
		if [ -n "${_UID:-}" ]; then
			_COMMIT_EMAIL="${_UID}+${GIT_USER_NAME}@users.noreply.github.com"
		fi
	fi
fi

if [ -z "${_COMMIT_EMAIL:-}" ]; then
	echo "agent-git-setup.sh: could not resolve any commit identity. Provide AGENT_GIT_BOT_ID, a resolvable AGENT_GIT_NAME, or GIT_USER_NAME (+ GIT_USER_ID / network)." >&2
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
