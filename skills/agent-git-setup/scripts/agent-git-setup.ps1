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
#   AGENT_GIT_ALLOW_TMP   *(default unset)* opt-in to allow running from
#                         an ephemeral location (for test harnesses).
#
# Usage:
#   agent-git-setup.ps1 --preflight --mode git-only|github [<repo-dir>]
#   agent-git-setup.ps1 <repo-dir>      # any worktree or the main repo of the repo
#
# Requires: git and PowerShell 7+ (Core). `gh` is additionally required for
# GitHub-mode preflight; setup resolves bot IDs through PowerShell's web API.

$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Argument / mode handling
# ---------------------------------------------------------------------------

$MODE = "setup"
$PREFLIGHT_MODE = ""
$REPO_ARGS = @()
foreach ($arg in $args) {
    if ($arg -eq "--preflight") {
        $MODE = "preflight"
    } elseif ($arg -eq "--mode") {
        $PREFLIGHT_MODE = "__NEXT__"
    } elseif ($PREFLIGHT_MODE -eq "__NEXT__") {
        $PREFLIGHT_MODE = $arg
    } else {
        $REPO_ARGS += $arg
    }
}

if ($MODE -eq "preflight" -and $PREFLIGHT_MODE -notin @("git-only", "github")) {
    Write-Error "agent-git-setup.ps1: --preflight requires --mode git-only or --mode github"
    exit 2
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
        Write-Host "agent-git-setup.ps1: PREFLIGHT FAIL: AGENT_GIT_NAME is unset." -ForegroundColor Red
        Write-Host "  Export AGENT_GIT_NAME (e.g. myagent[bot])."
        $ok = 1
    } else {
        $gitDir = (& git -C $REPO_PATH rev-parse --absolute-git-dir 2>$null).Replace('\', '/')
        $commonDir = (& git -C $REPO_PATH rev-parse --path-format=absolute --git-common-dir 2>$null).Replace('\', '/')
        $resolvedName = & git -C $REPO_PATH config user.name 2>$null
        $resolvedEmail = & git -C $REPO_PATH config user.email 2>$null
        if ($null -eq $resolvedEmail) { $resolvedEmail = "" }
        $authorIdent = & git -C $REPO_PATH var GIT_AUTHOR_IDENT 2>$null
        $committerIdent = & git -C $REPO_PATH var GIT_COMMITTER_IDENT 2>$null
        $escapedName = [regex]::Escape($env:AGENT_GIT_NAME)
        $emailPattern = '^[1-9][0-9]*\+' + $escapedName + '@users\.noreply\.github\.com$'
        $identityPattern = '^' + $escapedName + ' <' + [regex]::Escape($resolvedEmail) + '> '
        if ([string]::IsNullOrEmpty($gitDir) -or [string]::IsNullOrEmpty($commonDir) -or $gitDir -eq $commonDir) {
            Write-Host "agent-git-setup.ps1: PREFLIGHT FAIL: target is not a linked worktree of the configured repo." -ForegroundColor Red
            $ok = 1
        } elseif ($resolvedName -ne $env:AGENT_GIT_NAME -or $resolvedEmail -notmatch $emailPattern -or $authorIdent -notmatch $identityPattern -or $committerIdent -notmatch $identityPattern) {
            Write-Host "agent-git-setup.ps1: PREFLIGHT FAIL: bot author/committer identity is not effective at $REPO_PATH." -ForegroundColor Red
            Write-Host "  Expected $($env:AGENT_GIT_NAME) with its numeric GitHub noreply email; check local, worktree, and environment overrides."
            $ok = 1
        }
    }

    if ($PREFLIGHT_MODE -eq "github") {
        if ([string]::IsNullOrEmpty($env:GH_TOKEN) -or [string]::IsNullOrEmpty($env:AGENT_GIT_TOKEN_ACTOR) -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Write-Host "agent-git-setup.ps1: PREFLIGHT FAIL: github mode requires GH_TOKEN, AGENT_GIT_TOKEN_ACTOR, gh, and network access." -ForegroundColor Red
            $ok = 1
        } elseif ($env:AGENT_GIT_TOKEN_ACTOR -ine $env:AGENT_GIT_NAME) {
            Write-Host "agent-git-setup.ps1: PREFLIGHT FAIL: token provider actor '$($env:AGENT_GIT_TOKEN_ACTOR)' does not match '$($env:AGENT_GIT_NAME)'." -ForegroundColor Red
            $ok = 1
        } else {
            $accessibleRepo = & gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($accessibleRepo)) {
                Write-Host "agent-git-setup.ps1: PREFLIGHT FAIL: GitHub token cannot access the current repository." -ForegroundColor Red
                $ok = 1
            }
        }
    }

    if ($ok -ne 0) {
        Write-Host "agent-git-setup.ps1: preflight aborted (fail-closed). Fix the above and re-run." -ForegroundColor Red
        exit 1
    }
    Write-Host "agent-git-setup.ps1: preflight OK — linked worktree identity verified ($PREFLIGHT_MODE mode)."
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

# _ResolveId <handle>: print the numeric GitHub id for a handle, or empty.
# Uses the public API without GH_TOKEN; installation tokens cannot read arbitrary users.
function Resolve-Id {
    param([string]$Handle)
    $encoded = [System.Uri]::EscapeDataString($Handle)
    try {
        $result = Invoke-RestMethod -Uri "https://api.github.com/users/$encoded" -Headers @{ Accept = "application/vnd.github+json" } -ErrorAction Stop
        return $result.id.ToString()
    } catch {
        return ""
    }
}

# Commit email must resolve to the bot account. Never silently substitute the human identity.
# Resolution order:
#   1. AGENT_GIT_BOT_ID   -> <id>+<AGENT_GIT_NAME>@users.noreply.github.com   (offline-safe)
#   2. AGENT_GIT_NAME     -> API-resolved bot id
if (-not [string]::IsNullOrEmpty($env:AGENT_GIT_BOT_ID) -and $env:AGENT_GIT_BOT_ID -notmatch '^[1-9][0-9]*$') {
    Write-Host "agent-git-setup.ps1: AGENT_GIT_BOT_ID must be a positive integer without leading zeroes." -ForegroundColor Red
    exit 2
}
$COMMIT_EMAIL = ""
if (-not [string]::IsNullOrEmpty($env:AGENT_GIT_BOT_ID)) {
    $COMMIT_EMAIL = "$($env:AGENT_GIT_BOT_ID)+$($env:AGENT_GIT_NAME)@users.noreply.github.com"
} else {
    $botId = Resolve-Id $env:AGENT_GIT_NAME
    if (-not [string]::IsNullOrEmpty($botId)) {
        $COMMIT_EMAIL = "$botId+$($env:AGENT_GIT_NAME)@users.noreply.github.com"
    }
}
if ([string]::IsNullOrEmpty($COMMIT_EMAIL)) {
    Write-Host "agent-git-setup.ps1: could not resolve the bot account id. Provide numeric AGENT_GIT_BOT_ID or network access to the public GitHub user API." -ForegroundColor Red
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
            $path = $line.Substring("worktree ".Length).Replace('\', '/')
            $candidateGitDir = & git -C $path rev-parse --absolute-git-dir 2>$null
            $candidateCommonDir = & git -C $path rev-parse --path-format=absolute --git-common-dir 2>$null
            if ($LASTEXITCODE -eq 0 -and $candidateGitDir -ne $candidateCommonDir) {
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
