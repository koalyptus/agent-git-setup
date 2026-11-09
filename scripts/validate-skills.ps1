# Validate all SKILL.md packages against the Agent Skills spec (Windows).
$ErrorActionPreference = "Stop"

$ValidatorVersion = "0.2.0"
$Archive = "agent-skills-validator_${ValidatorVersion}_windows_amd64.zip"
$Sha256 = "8780fd9259b28dd0fbd1a59bac2e89585864815789af04890dc39d5cdf6826e5"
$Url = "https://github.com/coolapso/agent-skills-validator/releases/download/v$ValidatorVersion/$Archive"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$WorkDir = Join-Path $env:TEMP "agent-skills-validator-$ValidatorVersion"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$ArchivePath = Join-Path $WorkDir $Archive
$attempt = 0
while ($true) {
  try { Invoke-WebRequest -Uri $Url -OutFile $ArchivePath; break }
  catch { $attempt++; if ($attempt -ge 3) { throw }; Start-Sleep -Seconds 2 }
}
$actual = (Get-FileHash $ArchivePath -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $Sha256) { throw "checksum mismatch: $actual" }

Expand-Archive -Path $ArchivePath -DestinationPath $WorkDir -Force
$Bin = Join-Path $WorkDir "agent-skills-validator.exe"

$SkillDirs = Get-ChildItem -Path (Join-Path $RepoRoot "skills") -Recurse -Filter SKILL.md | ForEach-Object { $_.DirectoryName }
& $Bin validate @SkillDirs
Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue