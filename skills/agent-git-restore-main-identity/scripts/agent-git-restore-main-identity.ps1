$ErrorActionPreference = 'Stop'
if ($args.Count -gt 0 -and $args[0] -in @('-h', '--help')) {
	Write-Host 'Usage: agent-git-restore-main-identity.ps1 --confirm [<repo-dir>]'
	exit 0
}
$engine = Join-Path $PSScriptRoot 'lib' 'main-identity-core.ps1'
& $engine restore @args
exit 0
