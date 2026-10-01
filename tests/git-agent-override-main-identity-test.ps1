#!/usr/bin/env pwsh
# Hermetic coverage for the opt-in main-worktree identity script.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$overrideScript = Join-Path $repoRoot 'scripts' 'agent-git-override-main-identity.ps1'
$setupScript = Join-Path $repoRoot 'scripts' 'agent-git-setup.ps1'
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-git-override-main-identity-test-" + [guid]::NewGuid().ToString('N'))
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
    Write-Host '1. Explicit opt-in and bot commit in main worktree'
    $repo = MakeRepo 'repo-local-identity' $true
    AssertEq (RunScript $setupScript @($repo)) '0' 'existing setup succeeds'
    $linkedWorktree = Join-Path $sandbox 'linked-worktree-during-override'
    $null = & git -C $repo worktree add -q -b linked-during-override $linkedWorktree
    AssertEq (& git -C $linkedWorktree config user.name) $env:AGENT_GIT_NAME 'linked worktree inherits bot identity before override'
    if ((RunScript $overrideScript @($repo)) -eq 0) { Bad 'override must require confirmation' } else { Ok 'override requires confirmation' }
    AssertEq (RunScript $overrideScript @('--confirm', $repo)) '0' 'override succeeds after confirmation'
    AssertEq (& git -C $repo config --file (Join-Path $repo '.git' 'config') --get user.name) $env:AGENT_GIT_NAME 'bot name is repo-local'
    AssertEq (& git config --global user.name) 'global-human' 'global name remains unchanged'
    AssertEq (& git -C $linkedWorktree config user.name) $env:AGENT_GIT_NAME 'linked worktree remains bot-attributed during override'
    Add-Content -LiteralPath (Join-Path $repo 'file.txt') -Value 'bot commit'
    $null = & git -C $repo add file.txt
    $null = & git -C $repo commit -q -m bot-main-commit
    AssertEq (& git -C $repo log -1 --pretty='%an <%ae>') 'fixture-bot[bot] <123456789+fixture-bot[bot]@users.noreply.github.com>' 'main-worktree commit is bot-attributed'

    Write-Host '2. Operation rejects linked worktrees and missing setup identity'
    $worktree = Join-Path $sandbox 'linked-worktree'
    $null = & git -C $repo worktree add -q -b linked $worktree
    $worktreeExit = RunScript $overrideScript @('--confirm', $worktree)
    if ($worktreeExit -eq 0) { Bad 'override must reject linked worktree' } else { Ok 'override rejects linked worktree' }
    $repoUnconfigured = MakeRepo 'repo-unconfigured' $true
    $unconfiguredExit = RunScript $overrideScript @('--confirm', $repoUnconfigured)
    if ($unconfiguredExit -eq 0) { Bad 'override must require persisted setup identity' } else { Ok 'override requires persisted setup identity' }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$script:Pass passed; $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
