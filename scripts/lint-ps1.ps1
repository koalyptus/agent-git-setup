#!/usr/bin/env pwsh
#
# lint-ps1.ps1
#
# Wrapper around PSScriptAnalyzer. The cmdlet was renamed from
# Invoke-PSScriptAnalyzer to Invoke-ScriptAnalyzer in PSScriptAnalyzer
# 1.21+. We probe for whichever is exported, lint each file in its own
# invocation (Invoke-ScriptAnalyzer -Path only accepts a single value
# in 1.21+), and exit non-zero ONLY when at least one file reports an
# Error-severity issue. Warning/Information findings (e.g.
# PSAvoidUsingWriteHost on user-facing CLI output) are printed but do
# not fail the build.
#
# Usage: pwsh scripts/lint-ps1.ps1 <file.ps1> [<file2.ps1> ...]
# Exits 0 on success, 1 if any file has an Error-severity issue.

$ErrorActionPreference = "Stop"
if ($args.Count -lt 1) {
    Write-Error "usage: lint-ps1.ps1 <file.ps1> [<file2.ps1> ...]"
    exit 2
}
$installed = Get-Module -ListAvailable -Name PSScriptAnalyzer |
    Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $installed) {
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck -AcceptLicense
    $installed = Get-Module -ListAvailable -Name PSScriptAnalyzer |
        Sort-Object Version -Descending | Select-Object -First 1
}
if ($null -eq $installed) { Write-Error "PSScriptAnalyzer not found"; exit 1 }
Write-Host "Using PSScriptAnalyzer $($installed.Version) at $($installed.Path)"
Import-Module -Name $installed.Path -Force
$invoke = @("Invoke-ScriptAnalyzer", "Invoke-PSScriptAnalyzer") |
    Where-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if ($null -eq $invoke) {
    Write-Error "Neither Invoke-ScriptAnalyzer nor Invoke-PSScriptAnalyzer exported"
    exit 1
}
Write-Host "Using cmdlet: $invoke"
$failed = 0
foreach ($f in $args) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Warning "Skipping missing file: $f"
        continue
    }
    Write-Host "--- Linting $f ---"
    $result = & $invoke -Path $f -Severity Error
    if ($null -ne $result) { $result | Format-Table -AutoSize }
    if ($null -ne $result -and @($result).Count -gt 0) { $failed++ }
}
if ($failed -gt 0) {
    Write-Error "PSScriptAnalyzer found Error-severity issues in $failed file(s)"
    exit 1
}
Write-Host "PSScriptAnalyzer: no Error-severity issues found."
exit 0
