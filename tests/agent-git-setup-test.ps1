#!/usr/bin/env pwsh
#
# agent-git-setup-test.ps1
#
# Hermetic tests for agent-git-setup.ps1. Creates throwaway git repos +
# worktrees under $env:TEMP (the HARNESS owns the worktree; this script
# only writes identity to the shared repo config via includeIf). Needs
# only PowerShell 7+ and git.
#
# Mirrors tests/agent-git-setup-test.sh: same cases, same coverage,
# PowerShell-native (no bash, no shuf, no mktemp, no fake-gh bash heredoc).

$ErrorActionPreference = "Continue"

# Hermetic: never inherit ambient git author/committer identity from the
# caller's environment (a bot-commit export in the dev shell would otherwise
# leak into the worktree-commit assertions below).
Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" } | ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }
Remove-Item env:GH_TOKEN, env:GH_ENTERPRISE_TOKEN, env:GITHUB_TOKEN, env:GITHUB_APP_ID, env:GITHUB_APP_PEM, env:GITHUB_APP_INSTALL_ID, env:GH_HOST, env:GH_REPO -ErrorAction SilentlyContinue
Remove-Item env:AGENT_GIT_NAME, env:AGENT_GIT_BOT_ID, env:AGENT_GIT_TOKEN_ACTOR, env:GIT_USER_NAME, env:GIT_USER_ID, env:AGENT_GIT_ALLOW_HUMAN_ACTOR -ErrorAction SilentlyContinue

$ScriptDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)
$RepoRoot = Split-Path -Parent $ScriptDir
$Script = Join-Path $RepoRoot "scripts" "agent-git-setup.ps1"
$Sandbox = Join-Path $env:TEMP ("agent-git-setup-test-" + (Get-Date -Format "yyyyMMddHHmmssffffff"))
if (-not (Test-Path $Sandbox)) { New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null }
$env:HOME = $Sandbox
$env:GIT_CONFIG_GLOBAL = Join-Path $Sandbox ".gitconfig"
$env:GIT_CONFIG_NOSYSTEM = "1"
$env:GH_CONFIG_DIR = Join-Path $Sandbox "gh-config"
$env:GIT_TERMINAL_PROMPT = "0"
function Invoke-RestMethod { throw "Network access is disabled in the hermetic test suite." }
# Repos are intentionally throwaway (under $env:TEMP); opt the hardening guard in.
$env:AGENT_GIT_ALLOW_TMP = "1"

$script:Pass = 0
$script:Fail = 0
function Ok($Name) { $script:Pass++; Write-Host "  ok   - $Name" -ForegroundColor Green }
function Bad($Name) { $script:Fail++; Write-Host "  FAIL - $Name" -ForegroundColor Red }
function AssertEq($Actual, $Expected, $Name) {
    if ($Actual -eq $Expected) { Ok $Name } else { Bad "$Name (got '$Actual' expected '$Expected')" }
}
function Cleanup {
    Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    if ($script:Repo20) { Remove-Item $script:Repo20 -Recurse -Force -ErrorAction SilentlyContinue }
}

# make_repo [with-origin]: a main repo with an initial commit (account-owner identity).
$RepoSeq = 0
function MakeRepo($WithOrigin) {
    $script:RepoSeq++
    $Repo = Join-Path $Sandbox ("repo-" + $script:RepoSeq)
    Remove-Item $Repo -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sandbox "wt") -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $Repo -Force | Out-Null
    & git init -q -b main "$Repo"
    & git -C "$Repo" config user.name human
    & git -C "$Repo" config user.email human@example.com
    Set-Content -Path (Join-Path $Repo "file.txt") -Value "x" -NoNewline
    & git -C "$Repo" add file.txt
    & git -C "$Repo" -c user.name=human -c user.email=human@example.com commit -q -m init
    if ($WithOrigin -eq "with-origin") {
        & git -C "$Repo" remote add origin https://github.com/example/repo.git
    }
    return $Repo
}

# make_worktree <repo>: the HARNESS creates the worktree (not the script).
$WtSeq = 0
function MakeWorktree($Repo) {
    $script:WtSeq++
    $Name = "wt-" + $script:WtSeq
    $Dir = Join-Path $Sandbox "wt" ((Split-Path $Repo -Leaf) + "-" + $Name)
    if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    & git -C "$Repo" worktree add -q -b ("agent-" + $Name) "$Dir"
    return $Dir
}

function RunSetup($Repo, $SetupScript = $Script) {
    $output = & $SetupScript $Repo 2>&1 | Out-String
    $exitCode = $global:LASTEXITCODE
    if ($exitCode -ne 0) { Write-Host $output }
    return $exitCode
}

# make_fake_gh <kind> [login]: configure a PowerShell function mock; never invoke real gh.
function MakeFakeGh($Kind, $Login = "") {
    $global:FakeGhKind = $Kind
    $global:FakeGhLogin = $Login
}

function global:gh {
    if ($args[0] -eq "repo" -and $args[1] -eq "view") {
        if ($global:FakeGhKind -eq "repo-denied") {
            $global:LASTEXITCODE = 1
            return
        }
        $global:LASTEXITCODE = 0
        return "example/repo"
    }
    $global:LASTEXITCODE = 1
    return
}

try {
Write-Host "1. Happy path: one-off setup scopes all worktrees, main untouched"
$Repo = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$env:GH_TOKEN = "dummy"
$WtDir = MakeWorktree $Repo
$Rc = RunSetup $Repo
if ($Rc -eq 0) { Ok "script exits 0" } else { Bad "script should exit 0 (exit $Rc)" }
AssertEq (& git -C $Repo config user.name) "human" "main repo user.name stays the account owner's"
AssertEq (& git -C $Repo config user.email) "human@example.com" "main repo user.email stays the account owner's"
& git -C $Repo config --local --get-regexp '^includeif\.gitdir/i:\*\*/\.git/worktrees/\*\*.path' *> $null 2>&1
if ($LASTEXITCODE -eq 0) { Ok "includeIf entry written to .git/config" } else { Bad "includeIf entry missing" }
AssertEq (& git -C $WtDir config user.name) "fixture-bot[bot]" "worktree user.name = bot"
AssertEq (& git -C $WtDir config user.email) "123456789+fixture-bot[bot]@users.noreply.github.com" "worktree commit author is bot noreply"

Write-Host "2. Idempotent re-run"
$Rc = RunSetup $Repo
if ($Rc -eq 0) { Ok "second run exits 0" } else { Bad "second run failed (exit $Rc)" }
AssertEq (& git -C $WtDir config user.name) "fixture-bot[bot]" "still bot after re-run"

Write-Host "3. Future worktree (created AFTER setup) auto-inherits bot (no re-run)"
$WtDir = MakeWorktree $Repo
AssertEq (& git -C $WtDir config user.name) "fixture-bot[bot]" "future worktree auto-inherits bot"

Write-Host "4. Commit in worktree is authored as bot"
Set-Content -Path (Join-Path $WtDir "y.txt") -Value "y" -NoNewline
& git -C $WtDir add y.txt
& git -C $WtDir -c user.name=fixture-bot[bot] -c user.email=123456789+fixture-bot[bot]@users.noreply.github.com commit -q -m "bot commit" 2>$null
$Author = & git -C $WtDir log -1 --pretty='%an <%ae>'
AssertEq $Author "fixture-bot[bot] <123456789+fixture-bot[bot]@users.noreply.github.com>" "worktree commit author is bot noreply"

Write-Host "5. Missing required env: errors"
$Repo5 = MakeRepo "with-origin"
Remove-Item env:AGENT_GIT_NAME -ErrorAction SilentlyContinue
$Rc = RunSetup $Repo5
if ($Rc -ne 0) { Ok "exits non-zero without AGENT_GIT_NAME" } else { Bad "should fail without AGENT_GIT_NAME" }

Write-Host "6. Deprecated GIT_USER_NAME is ignored"
$Repo6 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$env:GIT_USER_NAME = "not a GitHub handle"
Remove-Item env:GIT_USER_ID -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
$Rc = RunSetup $Repo6
if ($Rc -eq 0) { Ok "setup ignores deprecated GIT_USER_NAME" } else { Bad "deprecated GIT_USER_NAME must not affect setup (exit $Rc)" }
Remove-Item env:GIT_USER_NAME -ErrorAction SilentlyContinue

Write-Host "7. Not-a-git-dir argument: errors"
$NotRepo = Join-Path $Sandbox "notarepo"
New-Item -ItemType Directory -Path $NotRepo -Force | Out-Null
$Rc = RunSetup $NotRepo
if ($Rc -ne 0) { Ok "exits non-zero on non-git dir" } else { Bad "should exit non-zero on non-git dir" }

Write-Host "8. Bot noreply email construction"
$Repo8 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "987654321"
$env:GH_TOKEN = "dummy"
$Rc = RunSetup $Repo8
if ($Rc -ne 0) { Bad "bot identity setup failed (exit $Rc)" }
$WtDir = MakeWorktree $Repo8
AssertEq (& git -C $WtDir config user.name) "fixture-bot[bot]" "fixture bot name"
AssertEq (& git -C $WtDir config user.email) "987654321+fixture-bot[bot]@users.noreply.github.com" "noreply from bot id (email uses bot name)"

Write-Host "9. Noreply from bot id via AGENT_GIT_BOT_ID (no network needed)"
$Repo9 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
Remove-Item env:GIT_USER_NAME -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
$Rc = RunSetup $Repo9
if ($Rc -ne 0) { Bad "offline bot identity setup failed (exit $Rc)" }
$WtDir = MakeWorktree $Repo9
AssertEq (& git -C $WtDir config user.email) "123456789+fixture-bot[bot]@users.noreply.github.com" "email from bot id (offline-safe)"

Write-Host "9a. Rejects malformed AGENT_GIT_BOT_ID"
$Repo9a = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "not-a-number"
$Rc = RunSetup $Repo9a
if ($Rc -ne 0) { Ok "rejects malformed bot ID" } else { Bad "malformed bot ID must fail" }
$env:AGENT_GIT_BOT_ID = "0"
$Rc = RunSetup $Repo9a
if ($Rc -ne 0) { Ok "rejects zero bot ID" } else { Bad "zero bot ID must fail" }

Write-Host "9b. Refuses human-email fallback when bot id cannot be resolved"
$Repo9b = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "unresolvable-bot-xyz[bot]"
$env:GIT_USER_NAME = "fixture-human"
$env:GIT_USER_ID = "123456789"
Remove-Item env:AGENT_GIT_BOT_ID -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
$Rc = RunSetup $Repo9b
if ($Rc -ne 0) { Ok "refuses human-email fallback" } else { Bad "setup must not silently substitute human email" }

Write-Host "10. No signing by default"
$Repo10 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$env:GH_TOKEN = "dummy"
$Rc = RunSetup $Repo10
if ($Rc -ne 0) { Bad "no-signing setup failed (exit $Rc)" }
if (-not (& git -C $Repo10 config commit.gpgsign 2>$null) -and -not (& git -C $Repo10 config user.signingkey 2>$null)) { Ok "no commit.gpgsign / user.signingkey set" } else { Bad "signing config unexpectedly set" }

Write-Host "11. No hooks / no core.hooksPath written (harness owns hooks)"
$Repo11 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$env:GH_TOKEN = "dummy"
$Rc = RunSetup $Repo11
if ($Rc -ne 0) { Bad "no-hooks setup failed (exit $Rc)" }
if (& git -C $Repo11 config core.hooksPath 2>$null) { Bad "script must not set core.hooksPath" } else { Ok "no core.hooksPath written" }

Write-Host "12. Ephemeral-location guard: refuses without opt-in"
$Repo12 = MakeRepo "with-origin"
Remove-Item env:AGENT_GIT_ALLOW_TMP -ErrorAction SilentlyContinue
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:GIT_USER_NAME = "fixture-human"
$env:GIT_USER_ID = "123456789"
$Rc = RunSetup $Repo12
if ($Rc -ne 0) { Ok "refuses ephemeral repo without opt-in" } else { Bad "should refuse ephemeral repo" }
$Repo13 = MakeRepo "with-origin"
$NestedScript = Join-Path $Repo13 "agent-git-setup.ps1"
Copy-Item $Script $NestedScript
$Rc = RunSetup $Repo13 $NestedScript
if ($Rc -ne 0) { Ok "refuses self-nesting" } else { Bad "should refuse self-nesting" }
Remove-Item (Join-Path $Repo13 "agent-git-setup.ps1") -Force -ErrorAction SilentlyContinue

Write-Host "14. Works when given a LINKED WORKTREE path (not just the main repo)"
$Repo14 = MakeRepo "with-origin"
$WtDir = MakeWorktree $Repo14
$env:AGENT_GIT_ALLOW_TMP = "1"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$Rc = RunSetup $WtDir
if ($Rc -eq 0) { Ok "script exits 0 from worktree path" } else { Bad "script should exit 0 from worktree path" }
AssertEq (& git -C $WtDir config user.name) "fixture-bot[bot]" "worktree-path input: worktree reads bot"
AssertEq (& git -C $Repo14 config user.name) "human" "worktree-path input: main stays the account owner's"

Write-Host "15. True failure only when NOTHING resolves (no bot id, no account-owner fallback)"
$Repo15 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "definitely-not-a-real-bot-xyz[bot]"
Remove-Item env:AGENT_GIT_BOT_ID -ErrorAction SilentlyContinue
Remove-Item env:GIT_USER_NAME -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
$Rc = RunSetup $Repo15
if ($Rc -ne 0) { Ok "exits non-zero when nothing resolves" } else { Bad "should exit non-zero when nothing resolves" }
if (-not (Test-Path (Join-Path $Repo15 ".git" "agent-bot-identity.config"))) { Ok "no bot config written when nothing resolves" } else { Bad "bot config written despite no resolvable identity" }

# --preflight tests use the fake global `gh` function above; the real CLI is never invoked.
function RunPreflight($Repo, $GhBin, $Mode = "github") {
    & $Script --preflight --mode $Mode $Repo *> $null
    return $global:LASTEXITCODE
}

Write-Host "16. Git-only preflight needs no token and requires a linked worktree"
$Repo16 = MakeRepo "with-origin"
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$Rc = RunPreflight $Repo16 $null "git-only"
if ($Rc -ne 0) { Ok "preflight exits non-zero in main repo" } else { Bad "exit code wrong" }
$WtDir = MakeWorktree $Repo16
$Rc = RunSetup $Repo16
if ($Rc -ne 0) { Bad "setup before Git-only preflight failed (exit $Rc)" }
$Rc = RunPreflight $WtDir $null "git-only"
if ($Rc -eq 0) { Ok "git-only preflight passes without GH_TOKEN" } else { Bad "git-only preflight should pass without GH_TOKEN" }
$env:GIT_AUTHOR_EMAIL = "123456789+human@users.noreply.github.com"
$Rc = RunPreflight $WtDir $null "git-only"
if ($Rc -ne 0) { Ok "rejects author email override" } else { Bad "preflight must reject author email override" }
Remove-Item env:GIT_AUTHOR_EMAIL -ErrorAction SilentlyContinue
$env:GIT_AUTHOR_NAME = "human"
$Rc = RunPreflight $WtDir $null "git-only"
if ($Rc -ne 0) { Ok "rejects author name override" } else { Bad "preflight must reject author name override" }
Remove-Item env:GIT_AUTHOR_NAME -ErrorAction SilentlyContinue
$env:GIT_COMMITTER_NAME = "human"
$Rc = RunPreflight $WtDir $null "git-only"
if ($Rc -ne 0) { Ok "rejects committer override" } else { Bad "preflight must reject committer override" }
Remove-Item env:GIT_COMMITTER_NAME -ErrorAction SilentlyContinue
$env:GIT_COMMITTER_EMAIL = "human@example.invalid"
$Rc = RunPreflight $WtDir $null "git-only"
if ($Rc -ne 0) { Ok "rejects committer email override" } else { Bad "preflight must reject committer email override" }
Remove-Item env:GIT_COMMITTER_EMAIL -ErrorAction SilentlyContinue

Write-Host "17. --preflight requires GH_TOKEN; passes when bot identity resolves"
$Repo17 = MakeRepo "with-origin"
$WtDir = MakeWorktree $Repo17
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$env:AGENT_GIT_TOKEN_ACTOR = "fixture-bot[bot]"
# Apply the bot identity to the repo (writes includeIf into the shared .git).
$Rc = RunSetup $Repo17
if ($Rc -ne 0) { Bad "setup before GitHub preflight failed (exit $Rc)" }
$GhBin = MakeFakeGh "app" "fixture-bot"
# 17a: no GH_TOKEN -> fail.
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -ne 0) { Ok "preflight exits non-zero without GH_TOKEN" } else { Bad "exit code wrong" }
# 17b: with GH_TOKEN + bot gh -> pass.
$env:GH_TOKEN = "dummy"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -eq 0) { Ok "preflight passes in linked worktree with bot identity + bot GH_TOKEN" } else { Bad "preflight should pass in linked worktree with bot identity + bot GH_TOKEN" }
$env:AGENT_GIT_TOKEN_ACTOR = "other-app[bot]"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -ne 0) { Ok "rejects mismatched App identity" } else { Bad "mismatched App identity must fail" }
$env:AGENT_GIT_TOKEN_ACTOR = "fixture-bot[bot]"
$GhBin = MakeFakeGh "repo-denied"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -ne 0) { Ok "rejects token without current-repository access" } else { Bad "inaccessible repository must fail" }

Write-Host "18. --preflight is location-agnostic but effect-strict: a SEPARATE clone still fails"
$Repo18c = MakeRepo "with-origin"
$Clone18 = Join-Path $Sandbox "clone18"
New-Item -ItemType Directory -Path $Clone18 -Force | Out-Null
& git clone --quiet "$Repo18c" "$Clone18" 2>$null
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$env:AGENT_GIT_TOKEN_ACTOR = "fixture-bot[bot]"
$env:GH_TOKEN = "dummy"
$Rc = RunPreflight $Clone18 $null "git-only"
if ($Rc -ne 0) { Ok "preflight fails closed in a separate clone (effect-based, not path-based)" } else { Bad "preflight must fail in a separate clone" }
Remove-Item $Clone18 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "19. --preflight verifies the GH_TOKEN actor is the BOT (not the account owner)."
$Repo19 = MakeRepo "with-origin"
$WtDir = MakeWorktree $Repo19
$env:AGENT_GIT_NAME = "fixture-bot[bot]"
$env:AGENT_GIT_BOT_ID = "123456789"
$env:GH_TOKEN = "dummy"
$Rc = RunSetup $Repo19
if ($Rc -ne 0) { Bad "setup before actor preflight failed (exit $Rc)" }
$env:AGENT_GIT_TOKEN_ACTOR = "fixture-bot[bot]"
# 19a: the matching bot account is accepted.
$GhBin = MakeFakeGh "bot-user" "fixture-bot[bot]"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -eq 0) { Ok "GitHub preflight passes for matching bot account" } else { Bad "GitHub preflight should pass for matching bot account" }
# 19b: human token (gh api user -> User), no consent -> preflight FAILS.
$GhBin = MakeFakeGh "human" "fixture-human"
$env:AGENT_GIT_TOKEN_ACTOR = "fixture-human[bot]"
Remove-Item env:AGENT_GIT_ALLOW_HUMAN_ACTOR -ErrorAction SilentlyContinue
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -ne 0) { Ok "preflight fails closed when GH_TOKEN actor is the account owner (no consent)" } else { Bad "exit code wrong" }
# 19c: human token, explicit consent -> pass.
$env:AGENT_GIT_ALLOW_HUMAN_ACTOR = "1"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -ne 0) { Ok "human actor remains rejected despite legacy consent flag" } else { Bad "human actor must remain rejected" }
Remove-Item env:AGENT_GIT_ALLOW_HUMAN_ACTOR -ErrorAction SilentlyContinue
# 19d: missing provider actor metadata fails closed.
Remove-Item env:AGENT_GIT_TOKEN_ACTOR -ErrorAction SilentlyContinue
$GhBin = MakeFakeGh "invalid"
$Rc = RunPreflight $WtDir $GhBin
if ($Rc -ne 0) { Ok "unverifiable actor fails closed" } else { Bad "unverifiable actor must fail" }
Remove-Item env:AGENT_GIT_ALLOW_HUMAN_ACTOR -ErrorAction SilentlyContinue
Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
Remove-Item env:AGENT_GIT_ALLOW_TMP -ErrorAction SilentlyContinue

# 20. Guard B: empty/unset $env:TEMP must NOT cause the script to refuse
# every repo (the "/" prefix bug). Run with TEMP and TMP cleared and the
# AGENT_GIT_ALLOW_TMP opt-out still off. The sandbox repo lives under
# $env:TEMP, so we need to opt the test in via the env var and then verify
# a repo under the workspace (outside TEMP and the guarded user-temp prefixes) is accepted.
Write-Host "20. Guard B: empty \$env:TEMP does not produce a '/' prefix that matches everything"
$Repo20 = Join-Path $RepoRoot (".agent-git-setup-persistent-" + $PID)
Remove-Item $Repo20 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Repo20 -Force | Out-Null
Push-Location $Repo20
& git init -q -b main $Repo20 2>$null | Out-Null
Pop-Location
$OrigTEMP = $env:TEMP
$OrigTMP  = $env:TMP
try {
    Remove-Item env:TEMP -ErrorAction SilentlyContinue
    Remove-Item env:TMP  -ErrorAction SilentlyContinue
    Remove-Item env:AGENT_GIT_ALLOW_TMP -ErrorAction SilentlyContinue
    $env:AGENT_GIT_NAME = "fixture-bot[bot]"
    $env:AGENT_GIT_BOT_ID = "123456789"
    $env:GIT_USER_NAME = "fixture-human"
    $env:GIT_USER_ID = "123456789"
    $Rc = RunSetup $Repo20
    if ($Rc -eq 0) { Ok "empty TEMP/TMP does not cause Guard B to false-positive" } else { Bad "Guard B refused a persistent repo with empty TEMP/TMP (rc=$Rc)" }
} finally {
    if ($null -ne $OrigTEMP) { $env:TEMP = $OrigTEMP }
    if ($null -ne $OrigTMP)  { $env:TMP  = $OrigTMP }
}

} finally {
    Cleanup
}

Write-Host "PASS=$Pass FAIL=$Fail"
if ($Fail -ne 0) { exit 1 }
