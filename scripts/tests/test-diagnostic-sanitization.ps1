Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repositoryRoot 'scripts\modules\TorChat.Diagnostics.psm1'
Import-Module $modulePath -Force -DisableNameChecking

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("torchat-diagnostics-test-" + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$run = Join-Path $root 'run'
$destination = Join-Path $root 'export.zip'
$expanded = Join-Path $root 'expanded'
New-Item -ItemType Directory -Force -Path $source,$run | Out-Null

try {
    $onion = ('a' * 56) + '.onion'
    $binary = [Convert]::ToBase64String((0..255))
    @"
{"body":"plaintext message","imageBase64":"$binary","sessionToken":"secret-token"}
Authorization: Bearer bearer-secret
TORCHAT_DATABASE_KEY=database-secret
endpoint=$onion
-----BEGIN PRIVATE KEY-----
private-material
-----END PRIVATE KEY-----
safe-id=abc123
"@ | Set-Content -LiteralPath (Join-Path $source 'runtime.log') -Encoding UTF8

    'binary database content' | Set-Content -LiteralPath (Join-Path $source 'client.sqlite') -Encoding UTF8
    'private key content' | Set-Content -LiteralPath (Join-Path $source 'identity.key') -Encoding UTF8
    'ordinary diagnostic line' | Set-Content -LiteralPath (Join-Path $source 'health.txt') -Encoding UTF8

    $context = [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        RunDirectory = $run
        RunId = 'sanitization-test'
    }
    [void](Export-TorChatDiagnostics -Context $context -SourceDirectory $source -Destination $destination)
    Expand-Archive -LiteralPath $destination -DestinationPath $expanded -Force

    Assert-True (Test-Path -LiteralPath (Join-Path $expanded 'sanitization-manifest.json')) 'Sanitization manifest is missing.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $expanded 'client.sqlite'))) 'SQLite database was included in diagnostic ZIP.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $expanded 'identity.key'))) 'Private key file was included in diagnostic ZIP.'

    $sanitized = Get-Content -LiteralPath (Join-Path $expanded 'runtime.log') -Raw
    foreach ($secret in @('plaintext message','secret-token','bearer-secret','database-secret','private-material',$onion,$binary)) {
        Assert-True (-not $sanitized.Contains($secret)) "Sensitive value survived sanitization: $secret"
    }
    foreach ($marker in @('<redacted>','<redacted-onion>','<redacted-key-material>','<redacted-binary-payload>','safe-id=abc123')) {
        Assert-True ($sanitized.Contains($marker)) "Expected sanitized marker is missing: $marker"
    }

    $manifest = Get-Content -LiteralPath (Join-Path $expanded 'sanitization-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.sanitized -eq $true) 'Manifest does not confirm sanitization.'
    Assert-True ($manifest.excludedSensitiveFiles -ge 2) 'Manifest did not record excluded sensitive files.'

    Write-Host 'TorChat diagnostic sanitization test passed.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
