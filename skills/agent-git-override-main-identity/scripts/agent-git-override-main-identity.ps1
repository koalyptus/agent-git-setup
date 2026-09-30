$ErrorActionPreference = 'Stop'
if ($args.Count -gt 0 -and $args[0] -in @('-h', '--help')) {
	Write-Host 'Usage: agent-git-override-main-identity.ps1 --confirm [<repo-dir>]'
	exit 0
}
$engine = Join-Path $PSScriptRoot 'lib' 'main-identity-core.ps1'
& $engine override @args
exit 0