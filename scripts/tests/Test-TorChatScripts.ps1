[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1', '.psm1') } |
    Sort-Object FullName)
$failures = New-Object System.Collections.ArrayList

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -eq 0) {
        Write-Host ("[PASS] {0}" -f $file.FullName.Substring($scriptsRoot.Length + 1)) -ForegroundColor Green
        continue
    }
    foreach ($parseError in $errors) {
        $record = [pscustomobject]@{
            File = $file.FullName
            Line = $parseError.Extent.StartLineNumber
            Column = $parseError.Extent.StartColumnNumber
            Message = $parseError.Message
        }
        [void]$failures.Add($record)
        Write-Host ("[FAIL] {0}:{1}:{2} {3}" -f $file.FullName, $record.Line, $record.Column, $record.Message) -ForegroundColor Red
    }
}

$removedEntryPoints = @(
    'start-dev.ps1',
    'redeploy.ps1',
    'full-deploy.ps1',
    'deploy-android.ps1',
    'deploy-windows.ps1',
    'run-android.ps1',
    'run-windows.ps1',
    'collect-logs.ps1'
)
foreach ($adapterName in $removedEntryPoints) {
    $adapterPath = Join-Path $scriptsRoot $adapterName
    if (Test-Path -LiteralPath $adapterPath) {
        $record = [pscustomobject]@{
            File = $adapterPath
            Line = 0
            Column = 0
            Message = 'Removed entry point was restored. Use scripts\\torchat.ps1.'
        }
        [void]$failures.Add($record)
        Write-Host ("[FAIL] {0} {1}" -f $adapterName, $record.Message) -ForegroundColor Red
    }
}

$entryPoint = Get-Content -LiteralPath (Join-Path $scriptsRoot 'torchat.ps1') -Raw
$startupContracts = @(
    @{
        Pattern = "(?s)'redeploy'\s*\{.*?\`$OnionPolicy\s*=\s*'preserve'"
        Message = 'redeploy must preserve the published relay onion'
    },
    @{
        Pattern = "(?s)'deploy-clean'\s*\{.*?\`$OnionPolicy\s*=\s*'rotate'"
        Message = 'deploy-clean must remain the explicit onion rotation workflow'
    }
)
foreach ($contract in $startupContracts) {
    if ($entryPoint -match $contract.Pattern) { continue }
    [void]$failures.Add([pscustomobject]@{
        File = (Join-Path $scriptsRoot 'torchat.ps1')
        Line = 0
        Column = 0
        Message = $contract.Message
    })
    Write-Host ("[FAIL] torchat.ps1 {0}" -f $contract.Message) -ForegroundColor Red
}

$androidModulePath = Join-Path $scriptsRoot 'modules\TorChat.Android.psm1'
$androidModule = Get-Content -LiteralPath $androidModulePath -Raw
if ($androidModule -match "Where-Object\s*\{\s*`$_\s*-notmatch\s*'\\\._adb-tls-connect") {
    [void]$failures.Add([pscustomobject]@{
        File = $androidModulePath
        Line = 0
        Column = 0
        Message = 'ADB mDNS transport serials must remain discoverable.'
    })
    Write-Host '[FAIL] TorChat.Android.psm1 filters a valid ADB mDNS device.' -ForegroundColor Red
}

$bootstrapPath = Join-Path (Split-Path -Parent $scriptsRoot) 'infra\host\bootstrap-staging.sh'
$bootstrap = Get-Content -LiteralPath $bootstrapPath -Raw
foreach ($requiredPattern in @(
    'secrets/pairing_secret',
    'head -c 64',
    'chmod 0600',
    'chown'
)) {
    if ($bootstrap -match [regex]::Escape($requiredPattern)) { continue }
    [void]$failures.Add([pscustomobject]@{
        File = $bootstrapPath
        Line = 0
        Column = 0
        Message = "Staging bootstrap is missing pairing-secret contract: $requiredPattern"
    })
    Write-Host "[FAIL] bootstrap-staging.sh missing $requiredPattern" -ForegroundColor Red
}

$composeHostPath = Join-Path (Split-Path -Parent $scriptsRoot) 'infra\docker\compose.host.yml'
$composeHost = Get-Content -LiteralPath $composeHostPath -Raw
foreach ($requiredPattern in @(
    'replicas:\s*1',
    'TORCHAT_PAIRING_SECRET_FILE:\s*/run/secrets/pairing_secret',
    'secrets:\s*- database_url\s*- pairing_secret',
    'condition:\s*service_healthy',
    'pg_isready -U torchat -d torchat',
    'test -s /var/lib/tor/hidden_service/hostname',
    'TORCHAT_SECURE_ROOT:\?TORCHAT_SECURE_ROOT is required',
    'driver:\s*json-file',
    'max-size:\s*10m',
    'max-file:\s*"7"'
)) {
    if ($composeHost -match $requiredPattern) { continue }
    [void]$failures.Add([pscustomobject]@{
        File = $composeHostPath
        Line = 0
        Column = 0
        Message = "Host Compose is missing deployment/secret/health contract: $requiredPattern"
    })
    Write-Host "[FAIL] compose.host.yml missing $requiredPattern" -ForegroundColor Red
}

if ($failures.Count -gt 0) {
    throw "PowerShell validation failed with $($failures.Count) error(s)."
}

Write-Host "Validated $($files.Count) PowerShell files and the single public entry point." -ForegroundColor Cyan
