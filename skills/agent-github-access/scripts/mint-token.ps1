[CmdletBinding()]
param(
    [string]$AppId,
    [string]$Pem,
    [string]$InstallationId,
    [string]$Credentials
)

$ErrorActionPreference = "Stop"

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-ConfiguredCredentials {
    param([string]$Path)

    $values = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*(?:export\s+)?(?<name>GITHUB_APP_ID|GITHUB_APP_PEM|GITHUB_APP_INSTALL_ID|AGENT_GIT_BOT_ID)\s*=\s*(?<value>.*)\s*$') {
            $value = $Matches.value.Trim()
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $values[$Matches.name] = $value
        }
    }
    return ,$values
}

try {
    $appIdArgumentProvided = $PSBoundParameters.ContainsKey('AppId')
    $pemArgumentProvided = $PSBoundParameters.ContainsKey('Pem')
    $installationArgumentProvided = $PSBoundParameters.ContainsKey('InstallationId')
    if ([string]::IsNullOrEmpty($Credentials)) { $Credentials = $env:AGENT_GIT_CREDENTIALS }

    $configRoot = if (-not [string]::IsNullOrEmpty($env:XDG_CONFIG_HOME)) {
        Join-Path $env:XDG_CONFIG_HOME 'agent-git-setup'
    } else {
        Join-Path $HOME '.config/agent-git-setup'
    }
    if ([string]::IsNullOrEmpty($Credentials) -and ([string]::IsNullOrEmpty($AppId) -or [string]::IsNullOrEmpty($Pem))) {
        $selectionAppId = if (-not [string]::IsNullOrEmpty($AppId)) { $AppId } else { $env:GITHUB_APP_ID }
        if (-not [string]::IsNullOrEmpty($selectionAppId)) {
            $perAppFile = Join-Path $configRoot "credentials.d/credentials-$selectionAppId.env"
            if (Test-Path -LiteralPath $perAppFile -PathType Leaf) { $Credentials = $perAppFile }
        }
        if ([string]::IsNullOrEmpty($Credentials)) {
            $defaultFile = Join-Path $configRoot 'credentials.env'
            if (Test-Path -LiteralPath $defaultFile -PathType Leaf) { $Credentials = $defaultFile }
        }
    }

    $configured = @{}
    if (-not [string]::IsNullOrEmpty($Credentials)) {
        if (-not (Test-Path -LiteralPath $Credentials -PathType Leaf)) {
            throw "credentials file not found: $Credentials"
        }
        $configured = Get-ConfiguredCredentials -Path (Resolve-Path -LiteralPath $Credentials).Path
    }

    if (-not $appIdArgumentProvided) {
        if ($configured.ContainsKey('GITHUB_APP_ID')) { $AppId = $configured.GITHUB_APP_ID }
        else { $AppId = $env:GITHUB_APP_ID }
    }
    if (-not $pemArgumentProvided) {
        if ($configured.ContainsKey('GITHUB_APP_PEM')) { $Pem = $configured.GITHUB_APP_PEM }
        else { $Pem = $env:GITHUB_APP_PEM }
    }
    if (-not $installationArgumentProvided) {
        if ($configured.ContainsKey('GITHUB_APP_INSTALL_ID')) { $InstallationId = $configured.GITHUB_APP_INSTALL_ID }
        else { $InstallationId = $env:GITHUB_APP_INSTALL_ID }
    }
    if ([string]::IsNullOrEmpty($AppId) -or $AppId -notmatch '^[0-9]+$') {
        throw 'set a numeric GITHUB_APP_ID, pass -AppId, or provide a credentials file'
    }
    if ([string]::IsNullOrEmpty($Pem)) {
        throw 'set GITHUB_APP_PEM, pass -Pem, or provide a credentials file'
    }
    if (-not [string]::IsNullOrEmpty($InstallationId) -and $InstallationId -notmatch '^[0-9]+$') {
        throw 'GITHUB_APP_INSTALL_ID / -InstallationId must be numeric'
    }
    if (-not (Test-Path -LiteralPath $Pem -PathType Leaf)) {
        throw "App private key file not found: $Pem"
    }
    $Pem = (Resolve-Path -LiteralPath $Pem).Path

    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem([System.IO.File]::ReadAllText($Pem))
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $header = [ordered]@{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
        $payload = [ordered]@{
            iat = [long]($now - 60)
            exp = [long]($now + 540)
            iss = [long]$AppId
        } | ConvertTo-Json -Compress
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $encodedHeader = ConvertTo-Base64Url -Bytes $utf8.GetBytes($header)
        $encodedPayload = ConvertTo-Base64Url -Bytes $utf8.GetBytes($payload)
        $jwtContent = "$encodedHeader.$encodedPayload"
        $jwtSignature = $rsa.SignData($utf8.GetBytes($jwtContent), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $appJwt = "$jwtContent.$(ConvertTo-Base64Url -Bytes $jwtSignature)"

        $headers = @{
            Authorization = "Bearer $appJwt"
            Accept = 'application/vnd.github+json'
        }
        $app = Invoke-RestMethod -Uri 'https://api.github.com/app' -Method Get -Headers $headers -ErrorAction Stop
        if ([string]$app.id -ne $AppId) {
            throw 'authenticated App ID did not match the requested ID'
        }

        $installations = @(Invoke-RestMethod -Uri 'https://api.github.com/app/installations' -Method Get -Headers $headers -ErrorAction Stop)
        if ([string]::IsNullOrEmpty($InstallationId)) {
            $installation = $installations | Select-Object -First 1
        } else {
            $installation = $installations | Where-Object { [string]$_.id -eq $InstallationId } | Select-Object -First 1
        }
        if ($null -eq $installation) {
            throw 'no installation found for this app'
        }

        $tokenResponse = Invoke-RestMethod -Uri "https://api.github.com/app/installations/$($installation.id)/access_tokens" -Method Post -Headers $headers -Body '' -ContentType 'application/vnd.github+json' -ErrorAction Stop
        if ([string]::IsNullOrEmpty([string]$tokenResponse.token)) {
            throw 'GitHub returned an empty installation token'
        }
        $token = [string]$tokenResponse.token
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $tokenHash = [Convert]::ToHexString($sha256.ComputeHash($utf8.GetBytes($token))).ToLowerInvariant()
        } finally {
            $sha256.Dispose()
        }
        $actor = "$($app.slug)[bot]"
        $statement = "agent-git-setup-token-v1`n$AppId`n$actor`n$tokenHash"
        $attestation = ConvertTo-Base64Url -Bytes $rsa.SignData($utf8.GetBytes($statement), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
        $rsa.Dispose()
    }

    $env:GH_TOKEN = $token
    $env:AGENT_GIT_TOKEN_ACTOR = $actor
    $env:AGENT_GIT_TOKEN_SHA256 = $tokenHash
    $env:AGENT_GIT_TOKEN_ATTESTATION = $attestation
    $env:AGENT_GIT_TOKEN_APP_ID = $AppId
    $env:AGENT_GIT_TOKEN_APP_PEM_PATH = $Pem
    $env:AGENT_GIT_TOKEN_APP_PEM_PATH_WINDOWS = $Pem
    if ($configured.ContainsKey('AGENT_GIT_BOT_ID')) {
        $env:AGENT_GIT_BOT_ID = $configured.AGENT_GIT_BOT_ID
    }
    Write-Host "mint-token.ps1: exported installation token and signed actor attestation for $actor."
} catch {
    Write-Host "mint-token.ps1: $($_.Exception.Message)" -ForegroundColor Red
    throw
}