#!/usr/bin/env pwsh
#
# agent-git-setup.ps1
#
# Give an AI agent its own git identity — commit author = <name>[bot].
#
# PowerShell port of scripts/agent-git-setup.sh. Identity-only: does NOT
# create worktrees, does NOT manage hooks, does NOT rewrite remotes, and
# does NOT impose a path or branch convention. Worktree lifecycle, hooks,
# and branching are the agent harness's responsibility.
#
# ONE-OFF PER REPO, ALL WORKTREES:
#   Instead of configuring each worktree separately, this script writes
#   the bot identity ONCE to the shared repo config using git's
#   conditional-include feature (`includeIf "gitdir/i:**/.git/worktrees/**"`).
#   Every linked worktree inherits the bot identity automatically —
#   including worktrees created AFTER this script runs.
#
# This script is completely backend/agent-neutral. It does NOT mint tokens
# and contains no secrets. It expects the desired bot identity in the
# environment, then writes it to repo-local git config so commits are
# authored as that bot identity — while your main checkout stays exactly as you.
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
# if it is missing — rather than silently falling back to the account owner's
# `gh auth`.
#
# PREFLOW GUARDRAIL:
#   Run `agent-git-setup.ps1 --preflight` BEFORE any git/gh work. It fails
#   non-zero (fail-closed) if the agent is in the MAIN repo (commits there would
#   be attributed to the account owner — the includeIf glob excludes the main
#   tree's .git, so a main-tree commit is attributed to the account owner) or if
#   `GH_TOKEN` is missing (no bot PR/API actor). This converts the most common
#   mis-attribution failure — an agent committing from the main tree as the
#   account owner — from documentation into a hard mechanism, without the script
#   ever creating or demanding a worktree. `--preflight` reads state only; it does
#   not manage worktrees or hooks.
#
# Required environment variables:
#   AGENT_GIT_NAME    Commit author name, e.g. myagent[bot].
#   GIT_USER_NAME     GitHub handle (e.g. my-git-user-name). LAST-RESORT
#                     fallback only: if the bot id cannot be resolved, commits
#                     are attributed to this account-owner handle. Prefer
#                     AGENT_GIT_BOT_ID / AGENT_GIT_NAME so commits stay bot.
#   GIT_USER_ID       Numeric GitHub user id (alternative to GIT_USER_NAME).
#                     If set, used directly as the fallback noreply prefix.
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
#   AGENT_GIT_ALLOW_HUMAN_ACTOR  *(default unset)* the agent sets this to
#                         `1` ONLY after the account owner explicitly approves
#                         acting as them (last resort when bot-token mint fails).
#   AGENT_GIT_ALLOW_TMP   *(default unset)* opt-in to allow running from
#                         an ephemeral location (for test harnesses).
#
# Usage:
#   agent-git-setup.ps1 --preflight [<repo-dir>]
#   agent-git-setup.ps1 <repo-dir>      # any worktree or the main repo of the repo
#
# Requires: git, gh (for `--preflight` actor verification and bot-id
# resolution), PowerShell 7+ (Core).

$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Argument / mode handling
# ---------------------------------------------------------------------------

$MODE = "setup"
$REPO_ARGS = @()
foreach ($arg in $args) {
    if ($arg -eq "--preflight") {
        $MODE = "preflight"
    } else {
        $REPO_ARGS += $arg
    }
}

if ($REPO_ARGS.Count -gt 0) {
    $REPO_PATH = (Resolve-Path $REPO_ARGS[0]).Path
} else {
    $REPO_PATH = (& git rev-parse --show-toplevel)
    if ($LASTEXITCODE -ne 0) {
        Write-Error "agent-git-setup.ps1: not a git repository"
        exit 2
    }
}

# Normalize to forward slashes for git config compatibility.
$REPO_PATH = $REPO_PATH.Replace('\', '/')

# ---------------------------------------------------------------------------
# Preflight: fail-closed state checks (read-only, no worktree management)
# ---------------------------------------------------------------------------

function Preflight {
    $ok = 0

    if ([string]::IsNullOrEmpty($env:AGENT_GIT_NAME)) {
        Write-Host "agent-git-setup.ps1: PREFLOW FAIL: AGENT_GIT_NAME is unset." -ForegroundColor Red
        Write-Host "  The bot commit identity cannot be verified without it. Export AGENT_GIT_NAME (e.g. myagent[bot])."
        $ok = 1
    } else {
        $resolved = & git -C $REPO_PATH config user.name 2>$null
        if ($LASTEXITCODE -ne 0) { $resolved = "" }
        if ($resolved -ne $env:AGENT_GIT_NAME) {
            Write-Host "agent-git-setup.ps1: PREFLOW FAIL: bot identity not in effect at $REPO_PATH." -ForegroundColor Red
            Write-Host "  Resolved user.name='$($resolved)' but expected '$($env:AGENT_GIT_NAME)'."
            Write-Host "  You are not in a linked worktree of the target repo where the bot identity"
            Write-Host "  applies (main checkout, detached checkout, or a separate clone all fail this)."
            Write-Host "  Run 'agent-git-setup.ps1 <repo-dir>' from a proper git worktree of the"
            Write-Host "  target repo, then re-run. Location is irrelevant — only that the bot identity resolves."
            $ok = 1
        }
    }

    if ([string]::IsNullOrEmpty($env:GH_TOKEN)) {
        Write-Host "agent-git-setup.ps1: PREFLOW FAIL: GH_TOKEN is unset." -ForegroundColor Red
        Write-Host "  The agent opens PRs / acts on GitHub AS THE BOT, so a token is required."
        Write-Host "  Mint one (scripts/mint-token.sh) and export GH_TOKEN before any git/gh work."
        $ok = 1
    } else {
        $actorType = ""
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            $who = & gh api user --jq '{type: .type, login: .login}' 2>$null
            $ghRc = $LASTEXITCODE
            if ($ghRc -eq 0) {
                $actorType = ($who | ConvertFrom-Json).type
            }
        }
        if ($actorType -eq "User") {
            if ($env:AGENT_GIT_ALLOW_HUMAN_ACTOR -eq "1") {
                Write-Host "agent-git-setup.ps1: PREFLOW WARN: proceeding as the account owner — approved explicitly; gh/API calls attributed to the account owner, not the bot." -ForegroundColor Yellow
            } else {
                Write-Host "agent-git-setup.ps1: PREFLOW FAIL: GH_TOKEN is the account owner's, not the bot." -ForegroundColor Red
                Write-Host "  (to the agent) gh/API calls would be attributed to the account owner, not the bot."
                Write-Host "  (to the agent) Fix: re-mint the bot token and export it before any gh/API work:"
                Write-Host "    source <(scripts/mint-token.sh --shell)"
                Write-Host "  (to the agent) If that fails, STOP and ask the account owner to approve acting as them;"
                Write-Host "  only on explicit approval set AGENT_GIT_ALLOW_HUMAN_ACTOR=1 and re-run preflight for this session."
                $ok = 1
            }
        } elseif ([string]::IsNullOrEmpty($actorType)) {
            if (Get-Command gh -ErrorAction SilentlyContinue) {
                # bot install token (403) or gh present but unverifiable — pass
            } else {
                Write-Host "agent-git-setup.ps1: PREFLOW WARN: could not verify GH_TOKEN actor (gh not installed / network unavailable)." -ForegroundColor Yellow
                Write-Host "  (to the agent) Cannot confirm the token is the App bot — if it is the account owner's PAT, gh/API"
                Write-Host "  calls will be attributed to the account owner. Re-mint the bot token (scripts/mint-token.sh"
                Write-Host "  --shell) and ensure gh + network before any gh/API work."
            }
        }
    }

    if ($ok -ne 0) {
        Write-Host "agent-git-setup.ps1: preflight aborted (fail-closed). Fix the above and re-run." -ForegroundColor Red
        exit 1
    }
    Write-Host "agent-git-setup.ps1: preflight OK — bot identity in effect, GH_TOKEN present."
    exit 0
}

if ($MODE -eq "preflight") {
    Preflight
}

# ---------------------------------------------------------------------------
# Setup path (from here down: only runs in setup mode)
# ---------------------------------------------------------------------------

if (-not (Test-Path "$REPO_PATH/.git")) {
    Write-Host "agent-git-setup.ps1: $REPO_PATH is not a git repository" -ForegroundColor Red
    exit 2
}

# The shared git directory (same for main and all its worktrees).
$GIT_DIR = & git -C $REPO_PATH rev-parse --absolute-git-dir
if ($LASTEXITCODE -ne 0) {
    Write-Host "agent-git-setup.ps1: could not locate the shared .git directory" -ForegroundColor Red
    exit 2
}
$GIT_DIR = $GIT_DIR.Replace('\', '/')

# If we are in a linked worktree, rev-parse points at
# <repo>/.git/worktrees/<name>; the shared dir is its parent's parent.
# Detect by path shape (a linked worktree's gitdir lives under .../.git/worktrees/<name>),
# NOT by the presence of config.worktree.
if ((Split-Path (Split-Path $GIT_DIR -Parent) -Leaf) -eq "worktrees") {
    $GIT_DIR = (Split-Path (Split-Path $GIT_DIR -Parent) -Parent)
}
if ((Split-Path $GIT_DIR -Leaf) -ne ".git") {
    Write-Host "agent-git-setup.ps1: could not locate the shared .git directory (got $GIT_DIR)" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# Hardening guards (deterministic, fail-closed)
# ---------------------------------------------------------------------------

$SCRIPT_DIR = (Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)).Replace('\', '/')

# Guard A — self-nesting: this tool must never be run from inside the repo it is
# meant to configure. agent-git-setup must be cloned OUTSIDE the target repo
# (e.g. /tmp/agent-git-setup or C:\tmp\agent-git-setup); otherwise we would
# write identity config into a repo that contains the tool itself. Refuse loudly.
if ($REPO_PATH -eq $SCRIPT_DIR -or $REPO_PATH.StartsWith("$SCRIPT_DIR/")) {
    Write-Host "agent-git-setup.ps1: ERROR: this script lives inside the target repo ($SCRIPT_DIR)." -ForegroundColor Red
    Write-Host "agent-git-setup.ps1: clone agent-git-setup OUTSIDE the repo and run from there." -ForegroundColor Red
    exit 2
}

# Guard B — stable location: the bot config is written at $GIT_DIR/agent-bot-identity.config
# and the includeIf points at that absolute path. If the repo's .git lives under an
# ephemeral location, that path is deleted when the session ends, leaving a dangling
# includeIf in the repo. Refuse in production; the test harness opts in with
# AGENT_GIT_ALLOW_TMP.
#
# $GIT_DIR was already slash-normalized above. We must also slash-normalize every
# candidate prefix, otherwise $env:TEMP (which on Windows uses backslashes) never
# matches via StartsWith. We also mirror the bash script's ephemeral set: /tmp,
# $TMPDIR, /dev/shm, plus the Windows-native TEMP/TMP and C:\Windows\Temp. An
# empty/unset env var must NOT contribute a "/" prefix that would match every
# path — we filter out empty entries.
$ephemeralPrefixes = @(
    'C:/Windows/Temp'
    'C:/Windows'
    'C:/Users'
    '/tmp'
    '/dev/shm'
)
if (-not [string]::IsNullOrEmpty($env:TEMP)) { $ephemeralPrefixes += $env:TEMP }
if (-not [string]::IsNullOrEmpty($env:TMP))  { $ephemeralPrefixes += $env:TMP  }
if (-not [string]::IsNullOrEmpty($env:TMPDIR)) { $ephemeralPrefixes += $env:TMPDIR }
$ephemeralPrefixes = $ephemeralPrefixes |
    ForEach-Object { $_.Replace('\', '/').TrimEnd('/') } |
    Where-Object { $_ -ne '' } |
    Sort-Object -Unique
foreach ($prefix in $ephemeralPrefixes) {
    if ($GIT_DIR.StartsWith("$prefix/", [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrEmpty($env:AGENT_GIT_ALLOW_TMP)) {
            Write-Host "agent-git-setup.ps1: ERROR: target repo's .git is in an ephemeral location ($GIT_DIR under $prefix/)." -ForegroundColor Red
            Write-Host "agent-git-setup.ps1: configure a persistent repo, not an ephemeral one." -ForegroundColor Red
            exit 2
        }
        break
    }
}

# Guard C — anti-bloat key: we always write this single, fixed includeIf key, so
# re-runs overwrite in place and can never accumulate duplicates.
$INCLUDE_KEY = 'includeIf.gitdir/i:**/.git/worktrees/**.path'

# ---------------------------------------------------------------------------
# Required environment
# ---------------------------------------------------------------------------

if ([string]::IsNullOrEmpty($env:AGENT_GIT_NAME)) {
    Write-Host "agent-git-setup.ps1: AGENT_GIT_NAME is required (e.g. myagent[bot])" -ForegroundColor Red
    exit 1
}

# Validate GIT_USER_NAME shape (GitHub handle: alphanumeric + hyphens).
function Test-ValidHandle {
    param([string]$Handle)
    return $Handle -match '^[A-Za-z0-9-]+$'
}
if (-not [string]::IsNullOrEmpty($env:GIT_USER_NAME) -and -not (Test-ValidHandle $env:GIT_USER_NAME)) {
    Write-Host "agent-git-setup.ps1: GIT_USER_NAME must be a GitHub handle ([A-Za-z0-9-] only), got: $($env:GIT_USER_NAME)" -ForegroundColor Red
    exit 2
}

# _ResolveId <handle>: print the numeric GitHub id for a handle, or empty.
# Uses the public API; sends GH_TOKEN as Bearer when set.
function Resolve-Id {
    param([string]$Handle)
    $encoded = [System.Uri]::EscapeDataString($Handle)
    $auth = @{}
    if (-not [string]::IsNullOrEmpty($env:GH_TOKEN)) {
        $auth["Authorization"] = "Bearer $($env:GH_TOKEN)"
    }
    try {
        $result = Invoke-RestMethod -Uri "https://api.github.com/users/$encoded" -Headers $auth -ErrorAction Stop
        return $result.id.ToString()
    } catch {
        return ""
    }
}

# Commit email: prefer the BOT's own noreply identity so commits show as the agent.
# Resolution order (bot-first, account-owner-fallback-last; fail only if nothing resolves):
#   1. AGENT_GIT_BOT_ID   -> <id>+<AGENT_GIT_NAME>@users.noreply.github.com   (offline-safe)
#   2. AGENT_GIT_NAME     -> API-resolved bot id (uses GH_TOKEN as Bearer if set)
#   3. GIT_USER_NAME      -> account-owner-attributed fallback
$COMMIT_EMAIL = ""
if (-not [string]::IsNullOrEmpty($env:AGENT_GIT_BOT_ID)) {
    $COMMIT_EMAIL = "$($env:AGENT_GIT_BOT_ID)+$($env:AGENT_GIT_NAME)@users.noreply.github.com"
} else {
    $botId = Resolve-Id $env:AGENT_GIT_NAME
    if (-not [string]::IsNullOrEmpty($botId)) {
        $COMMIT_EMAIL = "$botId+$($env:AGENT_GIT_NAME)@users.noreply.github.com"
    }
}
if ([string]::IsNullOrEmpty($COMMIT_EMAIL) -and -not [string]::IsNullOrEmpty($env:GIT_USER_NAME)) {
    if (-not [string]::IsNullOrEmpty($env:GIT_USER_ID)) {
        $COMMIT_EMAIL = "$($env:GIT_USER_ID)+$($env:GIT_USER_NAME)@users.noreply.github.com"
    } else {
        $uid = Resolve-Id $env:GIT_USER_NAME
        if (-not [string]::IsNullOrEmpty($uid)) {
            $COMMIT_EMAIL = "$uid+$($env:GIT_USER_NAME)@users.noreply.github.com"
        }
    }
}

if ([string]::IsNullOrEmpty($COMMIT_EMAIL)) {
    Write-Host "agent-git-setup.ps1: could not resolve any commit identity. Provide AGENT_GIT_BOT_ID, a resolvable AGENT_GIT_NAME, or GIT_USER_NAME (+ GIT_USER_ID / network)." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Write the bot identity ONCE, scoped to all worktrees via includeIf
# ---------------------------------------------------------------------------

$BOT_CONFIG = "$GIT_DIR/agent-bot-identity.config"

# Write the included config file (bot identity). It lives inside .git/ so it
# is never committed and stays per-clone/per-machine.
& git config -f "$BOT_CONFIG" user.name $env:AGENT_GIT_NAME
if ($LASTEXITCODE -ne 0) {
    Write-Host "agent-git-setup.ps1: ERROR: failed to write bot config" -ForegroundColor Red
    exit 2
}
& git config -f "$BOT_CONFIG" user.email $COMMIT_EMAIL
if ($LASTEXITCODE -ne 0) {
    Write-Host "agent-git-setup.ps1: ERROR: failed to write bot config" -ForegroundColor Red
    exit 2
}

# Conditional include: apply the bot config to every linked worktree
# (.git/worktrees/<name>) but NOT to the main repo's own .git directory.
& git -C $REPO_PATH config --local "$INCLUDE_KEY" "$BOT_CONFIG"
if ($LASTEXITCODE -ne 0) {
    Write-Host "agent-git-setup.ps1: ERROR: failed to write includeIf" -ForegroundColor Red
    exit 2
}

# Guard C (assert) — anti-bloat: exactly one includeIf entry must now exist.
$cfgCount = & git -C $REPO_PATH config --local --get-all "$INCLUDE_KEY" 2>$null | Measure-Object | ForEach-Object { $_.Count }
if ($cfgCount -ne 1) {
    Write-Host "agent-git-setup.ps1: ERROR: expected exactly one includeIf entry, found $cfgCount (config bloat)." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Verify: main stays the account owner's, worktrees become bot
# ---------------------------------------------------------------------------

# Main repo must remain the account owner's (the glob excludes its .git directory).
$mainUserName = & git --git-dir="$GIT_DIR" config user.name 2>$null
if ($LASTEXITCODE -ne 0) { $mainUserName = "" }
if ($mainUserName -eq $env:AGENT_GIT_NAME) {
    Write-Host "agent-git-setup.ps1: ERROR: bot identity leaked into the main repo" -ForegroundColor Red
    exit 1
}

# A worktree must read as the bot. If we are currently inside a linked
# worktree, verify it directly. Otherwise, if any linked worktree exists,
# verify the first one.
$currentGitDir = & git -C $REPO_PATH rev-parse --absolute-git-dir
$currentGitDir = $currentGitDir.Replace('\', '/')
if ((Split-Path (Split-Path $currentGitDir -Parent) -Leaf) -eq "worktrees") {
    $wtTest = $REPO_PATH
} else {
    $wtLines = & git -C $REPO_PATH worktree list --porcelain 2>$null
    $wtTest = ""
    foreach ($line in $wtLines) {
        if ($line.StartsWith("worktree ")) {
            $path = $line.Substring("worktree ".Length)
            if ($path -ne $REPO_PATH) {
                $wtTest = $path
                break
            }
        }
    }
}
if (-not [string]::IsNullOrEmpty($wtTest) -and (Test-Path "$wtTest/.git")) {
    $wtUserName = & git -C $wtTest config user.name 2>$null
    if ($LASTEXITCODE -ne 0) { $wtUserName = "" }
    if ($wtUserName -ne $env:AGENT_GIT_NAME) {
        Write-Host "agent-git-setup.ps1: ERROR: worktree did not pick up bot identity (got '$wtUserName')" -ForegroundColor Red
        exit 1
    }
}

Write-Host "agent-git-setup.ps1: isolation verified — main tree untouched, all worktrees bot"
Write-Host "agent-git-setup.ps1: one-off setup; future worktrees inherit bot identity automatically"
Write-Host "agent-git-setup.ps1: done. All worktrees in: $REPO_PATH"
Write-Host "  author = $($env:AGENT_GIT_NAME) <$COMMIT_EMAIL>"
Write-Host "  PR/API actor = bot via GH_TOKEN (agent opens PRs as the bot)"
