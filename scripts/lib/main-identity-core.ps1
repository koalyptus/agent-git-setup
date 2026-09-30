#!/usr/bin/env pwsh
# Enable or restore this clone's main-worktree bot commit identity.
$ErrorActionPreference = 'Stop'

function Stop-WithError([string]$Message) {
    Write-Error "main-identity-core.ps1: $Message"
    exit 1
}

function Invoke-Git([string[]]$GitArgs) {
    $output = @(& git @GitArgs 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "git $($GitArgs -join ' ') failed (exit $exitCode): $($output -join "`n")"
    }
    return $output
}

function Read-ConfigValue([string]$ConfigPath, [string]$Key) {
    $output = @(& git config --file $ConfigPath --get-all $Key 2>$null)
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 1) { return @{ Present = $false; Value = '' } }
    if ($exitCode -ne 0) { throw "could not read $Key from $ConfigPath (exit $exitCode)" }
    if ($output.Count -gt 1) { throw "multiple or multiline $Key entries found in $ConfigPath; refusing to change identity" }
    return @{ Present = $true; Value = [string]$output[0] }
}

function Write-ConfigValue([string]$ConfigPath, [string]$Key, [bool]$Present, [string]$Value) {
    if ($Present) {
        $null = Invoke-Git @('config', '--file', $ConfigPath, '--replace-all', $Key, $Value)
    } else {
        $null = & git config --file $ConfigPath --unset-all $Key 2>$null
        $exitCode = $LASTEXITCODE
        if ($exitCode -notin @(0, 5)) { throw "could not remove $Key from $ConfigPath (exit $exitCode)" }
    }
}

function Read-Backup {
    $version = Read-ConfigValue $script:BackupPath 'main-identity.version'
    if (-not $version.Present -or $version.Value -ne '1') { throw 'backup file is invalid or unsupported; preserve it and inspect it manually' }
    $script:BackupState = @{}
    foreach ($key in @('bot-name', 'bot-email', 'original-name-present', 'original-email-present', 'original-name', 'original-email')) {
        $value = Read-ConfigValue $script:BackupPath "main-identity.$key"
        $script:BackupState[$key] = if ($value.Present) { $value.Value } else { '' }
    }
    if ([string]::IsNullOrEmpty($script:BackupState['bot-name']) -or [string]::IsNullOrEmpty($script:BackupState['bot-email'])) {
        throw 'backup file has no bot identity; preserve it and inspect it manually'
    }
    if ($script:BackupState['original-name-present'] -notin @('true', 'false') -or $script:BackupState['original-email-present'] -notin @('true', 'false')) {
        throw 'backup file has invalid original identity state'
    }
}

function Restore-Original {
    Write-ConfigValue $script:LocalConfig 'user.name' ($script:BackupState['original-name-present'] -eq 'true') $script:BackupState['original-name']
    Write-ConfigValue $script:LocalConfig 'user.email' ($script:BackupState['original-email-present'] -eq 'true') $script:BackupState['original-email']
}

function Test-CurrentValue([hashtable]$Current, [string]$OriginalPresent, [string]$OriginalValue, [string]$BotValue) {
    if ($Current.Present -and $Current.Value -ceq $BotValue) { return $true }
    if ($OriginalPresent -eq 'true' -and $Current.Present -and $Current.Value -ceq $OriginalValue) { return $true }
    if ($OriginalPresent -eq 'false' -and -not $Current.Present) { return $true }
    return $false
}

$commandName = ''
$confirmed = $false
$repoArgument = ''
foreach ($argument in $args) {
    if ($argument -eq '--confirm') {
        $confirmed = $true
    } elseif ($argument -in @('-h', '--help')) {
        Write-Host 'Usage: main-identity-core.ps1 override|restore --confirm [<repo-dir>]'
        exit 0
    } elseif ($argument.StartsWith('-')) {
        Stop-WithError "unknown option: $argument"
    } elseif ([string]::IsNullOrEmpty($commandName)) {
        $commandName = $argument
    } elseif ([string]::IsNullOrEmpty($repoArgument)) {
        $repoArgument = $argument
    } else {
        Stop-WithError "unexpected argument: $argument"
    }
}
if ($commandName -notin @('override', 'restore')) { Stop-WithError 'choose override or restore' }
if (-not $confirmed) { Stop-WithError 'explicit user approval is required (--confirm)' }

try {
    if ([string]::IsNullOrEmpty($repoArgument)) {
        $repoArgument = [string](Invoke-Git @('rev-parse', '--show-toplevel'))
    }
    $repoPath = [System.IO.Path]::GetFullPath($repoArgument)
    $mainRoot = [string](Invoke-Git @('-C', $repoPath, 'rev-parse', '--show-toplevel'))
    $gitDir = [string](Invoke-Git @('-C', $mainRoot, 'rev-parse', '--absolute-git-dir'))
    $commonDir = [string](Invoke-Git @('-C', $mainRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($gitDir, $commonDir)) {
        Stop-WithError 'this operation is only for the main worktree; run it from the main worktree, not a linked worktree'
    }

    $script:LocalConfig = Join-Path $commonDir 'config'
    $botConfig = Join-Path $commonDir 'agent-bot-identity.config'
    $script:BackupPath = Join-Path $commonDir 'agent-main-identity.backup.config'
    if (-not (Test-Path -LiteralPath $script:LocalConfig -PathType Leaf)) { Stop-WithError 'repository-local Git config is missing' }

    if ($commandName -eq 'override') {
        if (-not (Test-Path -LiteralPath $botConfig -PathType Leaf)) { Stop-WithError 'bot identity is not configured; run agent-git-setup first' }
        $botNameValue = Read-ConfigValue $botConfig 'user.name'
        $botEmailValue = Read-ConfigValue $botConfig 'user.email'
        $botName = $botNameValue.Value
        $botEmail = $botEmailValue.Value
        if (-not $botNameValue.Present -or -not $botEmailValue.Present -or [string]::IsNullOrEmpty($botName) -or [string]::IsNullOrEmpty($botEmail)) {
            Stop-WithError 'persisted bot identity is incomplete; run agent-git-setup again'
        }
        if ($botName.Contains("`n") -or $botEmail.Contains("`n") -or $botEmail -notmatch '^[1-9][0-9]*\+' -or $botEmail.Substring($botEmail.IndexOf('+') + 1) -cne "$botName@users.noreply.github.com") {
            Stop-WithError 'persisted bot name and numeric GitHub noreply email do not match'
        }

        if (Test-Path -LiteralPath $script:BackupPath -PathType Leaf) {
            Read-Backup
            $currentName = Read-ConfigValue $script:LocalConfig 'user.name'
            $currentEmail = Read-ConfigValue $script:LocalConfig 'user.email'
            if (-not ($currentName.Present -and $currentName.Value -ceq $botName -and $currentEmail.Present -and $currentEmail.Value -ceq $botEmail)) {
                Stop-WithError 'backup exists but the main-worktree identity differs; restore or inspect it before overriding'
            }
            Write-Host "main-identity-core.ps1: bot identity is already active for $mainRoot"
            exit 0
        }

        $originalName = Read-ConfigValue $script:LocalConfig 'user.name'
        $originalEmail = Read-ConfigValue $script:LocalConfig 'user.email'
        $tempBackup = "$($script:BackupPath).tmp.$PID"
        if (Test-Path -LiteralPath $tempBackup) { Stop-WithError "temporary backup already exists: $tempBackup" }
        [System.IO.File]::WriteAllText($tempBackup, '')
        $null = Invoke-Git @('config', '--file', $tempBackup, 'main-identity.version', '1')
        $null = Invoke-Git @('config', '--file', $tempBackup, 'main-identity.bot-name', $botName)
        $null = Invoke-Git @('config', '--file', $tempBackup, 'main-identity.bot-email', $botEmail)
        $null = Invoke-Git @('config', '--file', $tempBackup, 'main-identity.original-name-present', $(if ($originalName.Present) { 'true' } else { 'false' }))
        $null = Invoke-Git @('config', '--file', $tempBackup, 'main-identity.original-email-present', $(if ($originalEmail.Present) { 'true' } else { 'false' }))
        if ($originalName.Present) { $null = Invoke-Git @('config', '--file', $tempBackup, 'main-identity.original-name', $originalName.Value) }
        if ($originalEmail.Present) { $null = Invoke-Git @('config', '--file', $tempBackup, 'main-identity.original-email', $originalEmail.Value) }
        if (Test-Path -LiteralPath $script:BackupPath) { Stop-WithError 'backup file appeared during activation; refusing to overwrite it' }
        [System.IO.File]::Move($tempBackup, $script:BackupPath)

        try {
            Write-ConfigValue $script:LocalConfig 'user.name' $true $botName
            Write-ConfigValue $script:LocalConfig 'user.email' $true $botEmail
            $currentName = Read-ConfigValue $script:LocalConfig 'user.name'
            $currentEmail = Read-ConfigValue $script:LocalConfig 'user.email'
            if (-not ($currentName.Present -and $currentName.Value -ceq $botName -and $currentEmail.Present -and $currentEmail.Value -ceq $botEmail)) {
                throw 'repo-local Git identity did not verify'
            }
            $authorIdent = [string](Invoke-Git @('-C', $mainRoot, 'var', 'GIT_AUTHOR_IDENT'))
            $committerIdent = [string](Invoke-Git @('-C', $mainRoot, 'var', 'GIT_COMMITTER_IDENT'))
            if (-not $authorIdent.StartsWith("$botName <$botEmail> ", [System.StringComparison]::Ordinal) -or -not $committerIdent.StartsWith("$botName <$botEmail> ", [System.StringComparison]::Ordinal)) {
                throw 'effective Git author/committer does not resolve to the bot; check environment overrides'
            }
        } catch {
            try { Read-Backup; Restore-Original; Remove-Item -LiteralPath $script:BackupPath -Force } catch { }
            throw
        }
        Write-Host "main-identity-core.ps1: bot identity enabled for main worktree $mainRoot"
        Write-Host 'main-identity-core.ps1: identity remains active until the restore command succeeds'
        exit 0
    }

    if (-not (Test-Path -LiteralPath $script:BackupPath -PathType Leaf)) { Stop-WithError 'no saved main-worktree identity exists for this repository' }
    Read-Backup
    $currentName = Read-ConfigValue $script:LocalConfig 'user.name'
    $currentEmail = Read-ConfigValue $script:LocalConfig 'user.email'
    if (-not (Test-CurrentValue $currentName $BackupState['original-name-present'] $BackupState['original-name'] $BackupState['bot-name'])) {
        Stop-WithError 'main-worktree user.name changed since override; refusing to overwrite it'
    }
    if (-not (Test-CurrentValue $currentEmail $BackupState['original-email-present'] $BackupState['original-email'] $BackupState['bot-email'])) {
        Stop-WithError 'main-worktree user.email changed since override; refusing to overwrite it'
    }
    Restore-Original
    $restoredName = Read-ConfigValue $script:LocalConfig 'user.name'
    $restoredEmail = Read-ConfigValue $script:LocalConfig 'user.email'
    if ($restoredName.Present -ne ($BackupState['original-name-present'] -eq 'true') -or ($restoredName.Present -and $restoredName.Value -cne $BackupState['original-name'])) {
        Stop-WithError 'restored user.name does not match backup; backup retained'
    }
    if ($restoredEmail.Present -ne ($BackupState['original-email-present'] -eq 'true') -or ($restoredEmail.Present -and $restoredEmail.Value -cne $BackupState['original-email'])) {
        Stop-WithError 'restored user.email does not match backup; backup retained'
    }
    Remove-Item -LiteralPath $script:BackupPath -Force
    Write-Host "main-identity-core.ps1: restored the saved main-worktree identity for $mainRoot"
    exit 0
} catch {
    if ($_.Exception.Message -like 'main-identity-core.ps1:*') { Write-Error $_.Exception.Message }
    else { Write-Error "main-identity-core.ps1: $($_.Exception.Message)" }
    exit 1
}