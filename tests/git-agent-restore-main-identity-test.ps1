#!/usr/bin/env pwsh
# Hermetic coverage for restoring the main-worktree identity.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$overrideScript = Join-Path $repoRoot 'scripts' 'agent-git-override-main-identity.ps1'
$restoreScript = Join-Path $repoRoot 'scripts' 'agent-git-restore-main-identity.ps1'
$setupScript = Join-Path $repoRoot 'scripts' 'agent-git-setup.ps1'
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("git-agent-restore-main-identity-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$env:HOME = $sandbox
$env:GIT_CONFIG_GLOBAL = Join-Path $sandbox 'global.gitconfig'
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:AGENT_GIT_ALLOW_TMP = '1'
$env:AGENT_GIT_NAME = 'fixture-bot[bot]'
$env:AGENT_GIT_BOT_ID = '123456789'
$null = & git config --global user.name global-human
$null = & git config --global user.email global@example.invalid

$script:Pass = 0
$script:Fail = 0
function Ok([string]$Name) { $script:Pass++; Write-Host "  ok   - $Name" -ForegroundColor Green }
function Bad([string]$Name) { $script:Fail++; Write-Host "  FAIL - $Name" -ForegroundColor Red }
function AssertEq([string]$Actual, [string]$Expected, [string]$Name) {
    if ($Actual -ceq $Expected) { Ok $Name } else { Bad "$Name (got '$Actual' expected '$Expected')" }
}
function MakeRepo([string]$Name, [bool]$SetLocalIdentity) {
    $path = Join-Path $sandbox $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $null = & git init -q -b main $path
    if ($SetLocalIdentity) {
        $null = & git -C $path config --local user.name repo-human
        $null = & git -C $path config --local user.email repo-human@example.invalid
    }
    Set-Content -LiteralPath (Join-Path $path 'file.txt') -Value 'initial' -NoNewline
    $null = & git -C $path add file.txt
    $null = & git -C $path -c user.name=seed -c user.email=seed@example.invalid commit -q -m init
    return $path
}
function RunScript([string]$Path, [string[]]$Arguments) {
    $null = & pwsh -NoProfile -File $Path @Arguments 2>&1
    return $LASTEXITCODE
}

try {
    Write-Host '1. Restore exact local identity and preserve linked-worktree bot identity'
    $repo = MakeRepo 'repo-local-identity' $true
    AssertEq (RunScript $setupScript @($repo)) '0' 'setup persists bot identity'
    $linkedWorktree = Join-Path $sandbox 'linked-worktree'
    $null = & git -C $repo worktree add -q -b linked $linkedWorktree
    AssertEq (RunScript $overrideScript @('--confirm', $repo)) '0' 'main-worktree override succeeds'
    if ((RunScript $restoreScript @($repo)) -eq 0) { Bad 'restore must require confirmation' } else { Ok 'restore requires confirmation' }
    AssertEq (RunScript $restoreScript @('--confirm', $repo)) '0' 'restore succeeds'
    AssertEq (& git -C $repo config --file (Join-Path $repo '.git' 'config') --get user.name) 'repo-human' 'saved local name restored'
    AssertEq (& git -C $repo config --file (Join-Path $repo '.git' 'config') --get user.email) 'repo-human@example.invalid' 'saved local email restored'
    AssertEq (& git -C $linkedWorktree config user.name) $env:AGENT_GIT_NAME 'linked worktree remains bot-attributed'
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git' 'agent-main-identity.backup.config'))) { Ok 'backup removed after successful restore' } else { Bad 'backup should be removed' }
    Add-Content -LiteralPath (Join-Path $repo 'file.txt') -Value 'human commit'
    $null = & git -C $repo add file.txt
    $null = & git -C $repo commit -q -m human-main-commit
    AssertEq (& git -C $repo log -1 --pretty='%an <%ae>') 'repo-human <repo-human@example.invalid>' 'main-worktree commit returns to saved identity'

    Write-Host '2. Refuse to overwrite identity changes and preserve backup'
    AssertEq (RunScript $overrideScript @('--confirm', $repo)) '0' 'second override succeeds'
    $null = & git -C $repo config --local user.email changed@example.invalid
    if ((RunScript $restoreScript @('--confirm', $repo)) -eq 0) { Bad 'restore should refuse changed identity' } else { Ok 'restore refuses changed identity' }
    if (Test-Path -LiteralPath (Join-Path $repo '.git' 'agent-main-identity.backup.config')) { Ok 'backup retained after conflict' } else { Bad 'backup must remain after conflict' }
    $null = & git -C $repo config --local user.name $env:AGENT_GIT_NAME
    $null = & git -C $repo config --local user.email '123456789+fixture-bot[bot]@users.noreply.github.com'
    AssertEq (RunScript $restoreScript @('--confirm', $repo)) '0' 'restore succeeds after resolving conflict'

    Write-Host '3. Remove temporary local values when original identity was inherited globally'
    $repoGlobal = MakeRepo 'repo-global-identity' $false
    AssertEq (RunScript $setupScript @($repoGlobal)) '0' 'setup succeeds for global identity fixture'
    AssertEq (RunScript $overrideScript @('--confirm', $repoGlobal)) '0' 'override succeeds without prior local identity'
    AssertEq (RunScript $restoreScript @('--confirm', $repoGlobal)) '0' 'restore succeeds without prior local identity'
    if ((& git -C $repoGlobal config --file (Join-Path $repoGlobal '.git' 'config') --get-all user.name 2>$null) -eq $null) { Ok 'repo-local name override removed' } else { Bad 'repo-local name override should be removed' }
    AssertEq (& git -C $repoGlobal config user.name) 'global-human' 'global identity is effective after restore'
    AssertEq (& git config --global user.name) 'global-human' 'global config remains untouched'

    Write-Host '4. Refuse linked-worktree restore and restore without a backup'
    if ((RunScript $restoreScript @('--confirm', $linkedWorktree)) -eq 0) { Bad 'restore must reject linked worktree' } else { Ok 'restore rejects linked worktree' }
    if ((RunScript $restoreScript @('--confirm', $repoGlobal)) -eq 0) { Bad 'restore must require a saved backup' } else { Ok 'restore requires saved backup' }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$script:Pass passed; $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
