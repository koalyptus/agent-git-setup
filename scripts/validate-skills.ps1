# Validate all SKILL.md packages against the Agent Skills spec (Windows).
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$WorkDir = Join-Path $env:TEMP "agent-skills-validator-$(New-Guid)"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/coolapso/agent-skills-validator/releases/latest"
$Version = $release.tag_name.TrimStart("v")
$Archive = "agent-skills-validator_${Version}_windows_amd64.zip"
$Url = "https://github.com/coolapso/agent-skills-validator/releases/download/v$Version/$Archive"
$ChecksumsUrl = "https://github.com/coolapso/agent-skills-validator/releases/download/v$Version/checksums.txt"

$ArchivePath = Join-Path $WorkDir $Archive
$ChecksumsPath = Join-Path $WorkDir "checksums.txt"

$attempt = 0
while ($true) {
  try { Invoke-WebRequest -Uri $Url -OutFile $ArchivePath; break }
  catch { $attempt++; if ($attempt -ge 3) { throw }; Start-Sleep -Seconds 2 }
}
Invoke-WebRequest -Uri $ChecksumsUrl -OutFile $ChecksumsPath

$expected = $null
foreach ($line in (Get-Content $ChecksumsPath)) {
  $parts = $line -split '\s+'
  if ($parts.Count -ge 2 -and $parts[1] -eq $Archive) { $expected = $parts[0]; break }
}
if (-not $expected) { throw "checksum entry not found for $Archive" }

$actual = (Get-FileHash $ArchivePath -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected.ToLower()) { throw "checksum mismatch: $actual" }

Expand-Archive -Path $ArchivePath -DestinationPath $WorkDir -Force
$Bin = Join-Path $WorkDir "agent-skills-validator.exe"

$SkillDirs = Get-ChildItem -Path (Join-Path $RepoRoot "skills") -Recurse -Filter SKILL.md | ForEach-Object { $_.DirectoryName }
if (-not $SkillDirs) { throw "No SKILL.md files found" }

$exitCode = 0
& $Bin validate @SkillDirs
$exitCode = $LASTEXITCODE
Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
exit $exitCode
