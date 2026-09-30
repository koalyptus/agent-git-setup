#!/usr/bin/env pwsh
# Hermetic coverage for the Windows agent-github-access workflow.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)
$RepoRoot = Split-Path -Parent $ScriptDir
$Minter = Join-Path $RepoRoot "skills" "agent-github-access" "scripts" "mint-token.ps1"
$SkillDoc = Join-Path $RepoRoot "skills" "agent-github-access" "SKILL.md"
$GitSkillDoc = Join-Path $RepoRoot "skills" "agent-git-setup" "SKILL.md"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-github-access-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

$EnvironmentNames = @(
    "XDG_CONFIG_HOME", "GH_TOKEN", "GH_ENTERPRISE_TOKEN", "GH_HOST", "GH_REPO",
    "GITHUB_TOKEN", "GITHUB_APP_ID", "GITHUB_APP_PEM", "GITHUB_APP_INSTALL_ID", "AGENT_GIT_CREDENTIALS",
    "AGENT_GIT_TOKEN_ACTOR", "AGENT_GIT_TOKEN_SHA256", "AGENT_GIT_TOKEN_ATTESTATION",
    "AGENT_GIT_TOKEN_APP_ID", "AGENT_GIT_TOKEN_APP_PEM_PATH", "AGENT_GIT_TOKEN_APP_PEM_PATH_WINDOWS",
    "AGENT_GIT_BOT_ID", "AGENT_GIT_NAME", "AGENT_GIT_ALLOW_TMP"
)
$SavedEnvironment = @{}
foreach ($name in $EnvironmentNames) {
    $SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
}
$SavedGitEnvironment = @{}
foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" }) {
    $SavedGitEnvironment[$item.Name] = $item.Value
    Remove-Item "Env:$($item.Name)" -ErrorAction SilentlyContinue
}

$GlobalNames = @("ApiCalls", "TokenByInstallation", "AppResponseId", "ExpectedOrigin", "ExpectedInstallationId", "FakeGhCalls", "FixtureRsa", "FixturePemPath", "LASTEXITCODE")
$SavedGlobals = @{}
foreach ($name in $GlobalNames) {
    $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    $SavedGlobals[$name] = if ($null -ne $variable) { $variable.Value } else { $null }
    Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
}
$ExistingGhFunction = Get-Item Function:\global:gh -ErrorAction SilentlyContinue

$global:ApiCalls = [System.Collections.Generic.List[object]]::new()
$global:TokenByInstallation = @{
    "42" = "ghs.synthetic-installation-token"
    "84" = "ghs.synthetic-override-token"
}
$global:AppResponseId = 1234567
$global:ExpectedOrigin = "https://github.com/acme/widget.git"
$global:ExpectedInstallationId = "42"
$global:FakeGhCalls = [System.Collections.Generic.List[string]]::new()
$global:FixtureRsa = [System.Security.Cryptography.RSA]::Create(2048)
$global:FixturePemPath = Join-Path $TestRoot "fixture-app.pem"
[System.IO.File]::WriteAllText($global:FixturePemPath, $global:FixtureRsa.ExportPkcs8PrivateKeyPem())

$script:Pass = 0
$script:Fail = 0
function Ok([string]$Name) { $script:Pass++; Write-Host "  ok   - $Name" -ForegroundColor Green }
function Bad([string]$Name) { $script:Fail++; Write-Host "  FAIL - $Name" -ForegroundColor Red }

function Invoke-RestMethod {
    param(
        [string]$Uri,
        [string]$Method,
        [hashtable]$Headers,
        [string]$Body,
        [string]$ContentType,
        [string]$ErrorAction
    )
    if ($Uri -notlike "https://api.github.com/*") { throw "Unexpected network request: $Uri" }
    if ($Headers.Authorization -notmatch '^Bearer (?<jwt>[^.]+\.[^.]+\.[^.]+)$') { throw "Missing App JWT authorization for $Uri" }
    $jwtParts = $Matches.jwt.Split('.')
    $payloadBytes = [Convert]::FromBase64String($jwtParts[1].Replace('-', '+').Replace('_', '/') + ('=' * ((4 - ($jwtParts[1].Length % 4)) % 4)))
    $jwtPayload = [System.Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json
    $signatureBytes = [Convert]::FromBase64String($jwtParts[2].Replace('-', '+').Replace('_', '/') + ('=' * ((4 - ($jwtParts[2].Length % 4)) % 4)))
    $publicKey = [System.Security.Cryptography.RSA]::Create()
    try {
        $bytesRead = 0
        $publicKey.ImportSubjectPublicKeyInfo($global:FixtureRsa.ExportSubjectPublicKeyInfo(), [ref]$bytesRead)
        $signedContent = [System.Text.Encoding]::UTF8.GetBytes("$($jwtParts[0]).$($jwtParts[1])")
        $jwtValid = $publicKey.VerifyData($signedContent, $signatureBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
        $publicKey.Dispose()
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not $jwtValid -or $jwtPayload.iss -ne 1234567 -or $jwtPayload.iat -gt $now -or $jwtPayload.exp -lt $now) {
        throw "Invalid App JWT signature or claims for $Uri"
    }
    $global:ApiCalls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body })

    if ($Uri -eq "https://api.github.com/app") { return @{ id = $global:AppResponseId; slug = "fixture-app" } }
    if ($Uri -eq "https://api.github.com/app/installations") { return @(@{ id = 42 }, @{ id = 84 }) }
    if ($Uri -match '^https://api\.github\.com/app/installations/(42|84)/access_tokens$') {
        $installationId = $Matches[1]
        return @{ token = $global:TokenByInstallation[$installationId] }
    }
    throw "Unexpected GitHub API request: $Method $Uri"
}

function global:gh {
    $call = $args -join " "
    $global:FakeGhCalls.Add($call)
    if ($call -ne "repo view --json nameWithOwner --jq .nameWithOwner") {
        throw "Unexpected gh invocation: $call"
    }
    if ($env:GH_TOKEN -ne $global:TokenByInstallation[$global:ExpectedInstallationId]) {
        throw "gh received an unexpected GH_TOKEN"
    }
    if ((& git remote get-url origin) -ne $global:ExpectedOrigin) {
        throw "gh verification did not run in the expected repository"
    }
    $global:LASTEXITCODE = 0
    return "acme/widget"
}

try {
    $env:XDG_CONFIG_HOME = Join-Path $TestRoot "xdg"
    $env:GIT_CONFIG_GLOBAL = Join-Path $TestRoot "gitconfig"
    $env:GIT_CONFIG_NOSYSTEM = "1"
    $gitSkillText = [System.IO.File]::ReadAllText($GitSkillDoc)
    $accessSkillText = [System.IO.File]::ReadAllText($SkillDoc)
    if ($gitSkillText.Contains("May I create commits as this human identity") -and $gitSkillText.Contains("If the human declines") -and $accessSkillText.Contains("May I perform") -and $accessSkillText.Contains("Only after explicit approval") -and $accessSkillText.Contains("show the public App IDs from their filenames") -and $accessSkillText.Contains("ask the human which App to use")) {
        Ok "both skills require consent and access skill resolves multiple App configs explicitly"
    } else {
        Bad "skills must require consent and explicit App choice when credentials are ambiguous"
    }

    $configDir = Join-Path $env:XDG_CONFIG_HOME "agent-git-setup"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $credentialsFile = Join-Path $configDir "credentials.env"
    [System.IO.File]::WriteAllText($credentialsFile, "GITHUB_APP_ID=1234567`nGITHUB_APP_PEM=$global:FixturePemPath`n")
    $credentialsBefore = [System.IO.File]::ReadAllBytes($credentialsFile)

    $repo = Join-Path $TestRoot "repo"
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q
    if ($LASTEXITCODE -ne 0) { throw "git init failed" }
    & git -C $repo remote add origin $global:ExpectedOrigin
    if ($LASTEXITCODE -ne 0) { throw "git remote add failed" }
    Push-Location $repo
    try {
        & $Minter
        if ($env:GH_TOKEN -eq $global:TokenByInstallation["42"] -and $env:AGENT_GIT_TOKEN_ACTOR -eq "fixture-app[bot]") {
            Ok "reads existing config and exports the installation token and App actor"
        } else {
            Bad "minter did not export token and App actor"
        }

        $expectedHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($env:GH_TOKEN))).ToLowerInvariant()
        $expectedStatement = "agent-git-setup-token-v1`n1234567`nfixture-app[bot]`n$expectedHash"
        $signature = $env:AGENT_GIT_TOKEN_ATTESTATION.Replace('-', '+').Replace('_', '/')
        $signature += '=' * ((4 - ($signature.Length % 4)) % 4)
        $validSignature = $global:FixtureRsa.VerifyData([System.Text.Encoding]::UTF8.GetBytes($expectedStatement), [Convert]::FromBase64String($signature), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if ($env:AGENT_GIT_TOKEN_SHA256 -eq $expectedHash -and $validSignature) {
            Ok "exports an attestation bound to the exact token"
        } else {
            Bad "token hash or App-key attestation is invalid"
        }

        $repository = & gh repo view --json nameWithOwner --jq .nameWithOwner
        if ($repository -eq "acme/widget" -and $global:FakeGhCalls.Count -eq 1) {
            Ok "verifies current-repository access through gh"
        } else {
            Bad "gh verification did not return the current repository"
        }

        $actualCredentials = [System.IO.File]::ReadAllBytes($credentialsFile)
        $tokenFiles = Get-ChildItem -LiteralPath $TestRoot -File -Recurse | Where-Object { $_.FullName -ne $credentialsFile -and $_.FullName -ne $global:FixturePemPath }
        $tokenPersisted = $false
        foreach ($file in $tokenFiles) {
            if ([System.IO.File]::ReadAllText($file.FullName).Contains($env:GH_TOKEN)) { $tokenPersisted = $true }
        }
        if ([Convert]::ToBase64String($credentialsBefore) -eq [Convert]::ToBase64String($actualCredentials) -and -not $tokenPersisted) {
            Ok "does not modify credentials or persist the installation token"
        } else {
            Bad "credentials changed or token was persisted"
        }

        $perAppDirectory = Join-Path $configDir "credentials.d"
        New-Item -ItemType Directory -Path $perAppDirectory -Force | Out-Null
        $perAppCredentials = Join-Path $perAppDirectory "credentials-1234567.env"
        [System.IO.File]::WriteAllText($perAppCredentials, "GITHUB_APP_ID=1234567`nGITHUB_APP_PEM=$global:FixturePemPath`n")
        [System.IO.File]::WriteAllText($credentialsFile, "GITHUB_APP_ID=7654321`nGITHUB_APP_PEM=$($TestRoot)/missing.pem`n")
        $global:ApiCalls.Clear()
        $env:GITHUB_APP_ID = "1234567"
        Remove-Item Env:GITHUB_APP_PEM -ErrorAction SilentlyContinue
        & $Minter
        if ($env:GH_TOKEN -eq $global:TokenByInstallation["42"] -and $global:ApiCalls.Count -eq 3) {
            Ok "per-App credentials take precedence over the global file"
        } else {
            Bad "did not select the matching per-App credentials"
        }
        [System.IO.File]::WriteAllBytes($credentialsFile, $credentialsBefore)
        Remove-Item Env:GITHUB_APP_ID -ErrorAction SilentlyContinue

        $credentialsBackup = Join-Path $TestRoot "credentials.backup"
        Move-Item -LiteralPath $credentialsFile -Destination $credentialsBackup
        try {
            $global:ApiCalls.Clear()
            $env:GITHUB_APP_ID = "1234567"
            $env:GITHUB_APP_PEM = $global:FixturePemPath
            & $Minter
            if ($env:GH_TOKEN -eq $global:TokenByInstallation["42"] -and $global:ApiCalls.Count -eq 3) {
                Ok "uses environment credentials when no credentials file exists"
            } else {
                Bad "environment credential fallback did not mint a token"
            }
        } finally {
            Remove-Item Env:GITHUB_APP_ID, Env:GITHUB_APP_PEM -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $credentialsBackup -Destination $credentialsFile
        }

        $global:ApiCalls.Clear()
        $global:ExpectedInstallationId = "84"
        & $Minter -InstallationId 84
        if ($env:GH_TOKEN -eq $global:TokenByInstallation["84"] -and $global:ApiCalls[-1].Uri.EndsWith("/app/installations/84/access_tokens")) {
            Ok "honors an explicitly selected installation"
        } else {
            Bad "explicit installation selection was not honored"
        }

        $global:ApiCalls.Clear()
        $global:ExpectedInstallationId = "42"
        $env:GITHUB_APP_ID = "1234567"
        $env:GITHUB_APP_PEM = Join-Path $TestRoot "missing.pem"
        & $Minter -AppId 1234567 -Pem $global:FixturePemPath
        if ($env:GH_TOKEN -eq $global:TokenByInstallation["42"]) {
            Ok "explicit credential arguments take precedence over ambient environment"
        } else {
            Bad "explicit arguments did not take precedence"
        }

        $global:ApiCalls.Clear()
        $global:AppResponseId = 7654321
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        try {
            & $Minter -AppId 1234567 -Pem $global:FixturePemPath
            Bad "mismatched authenticated App ID should fail"
        } catch {
            $tokenRequests = @($global:ApiCalls | Where-Object { $_.Uri -like '*/access_tokens' })
            if ([string]::IsNullOrEmpty($env:GH_TOKEN) -and $tokenRequests.Count -eq 0) {
                Ok "rejects mismatched authenticated App ID before minting"
            } else {
                Bad "mismatched App ID minted or retained a token"
            }
        }

        $global:ApiCalls.Clear()
        $global:AppResponseId = 1234567
        try {
            & $Minter -AppId 1234567 -Pem $global:FixturePemPath -InstallationId 999
            Bad "missing selected installation should fail"
        } catch {
            $tokenRequests = @($global:ApiCalls | Where-Object { $_.Uri -like '*/access_tokens' })
            if ($tokenRequests.Count -eq 0) {
                Ok "fails closed when explicit installation is unavailable"
            } else {
                Bad "requested unavailable installation was used to mint a token"
            }
        }

        if ($global:ApiCalls.Count -eq 0) { Bad "expected mint requests were not made" }
    } finally {
        Pop-Location
    }

    if ($script:Fail -eq 0) {
        Write-Host "PASS=$($script:Pass) FAIL=0"
    } else {
        Write-Host "PASS=$($script:Pass) FAIL=$($script:Fail)"
        exit 1
    }
} catch {
    Write-Host $_.ScriptStackTrace
    Write-Error $_
    exit 1
} finally {
    if ($global:FixtureRsa) { $global:FixtureRsa.Dispose() }
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($name in $EnvironmentNames) {
        [Environment]::SetEnvironmentVariable($name, $SavedEnvironment[$name], "Process")
    }
    foreach ($name in $SavedGitEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $SavedGitEnvironment[$name], "Process")
    }
    foreach ($name in $GlobalNames) {
        if ($null -ne $SavedGlobals[$name]) {
            Set-Variable -Name $name -Scope Global -Value $SavedGlobals[$name]
        } else {
            Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $ExistingGhFunction) {
        Set-Item Function:\global:gh -Value $ExistingGhFunction.ScriptBlock
    } else {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
    }
}