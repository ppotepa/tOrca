[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Include '*.ps1','*.psm1' | Sort-Object FullName)
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
    foreach ($error in $errors) {
        $record = [pscustomobject]@{
            File = $file.FullName
            Line = $error.Extent.StartLineNumber
            Column = $error.Extent.StartColumnNumber
            Message = $error.Message
        }
        [void]$failures.Add($record)
        Write-Host ("[FAIL] {0}:{1}:{2} {3}" -f $file.FullName, $record.Line, $record.Column, $record.Message) -ForegroundColor Red
    }
}

$adapterNames = @(
    'start-dev.ps1',
    'redeploy.ps1',
    'full-deploy.ps1',
    'deploy-android.ps1',
    'deploy-windows.ps1',
    'run-android.ps1',
    'run-windows.ps1',
    'collect-logs.ps1'
)
foreach ($adapterName in $adapterNames) {
    $adapterPath = Join-Path $scriptsRoot $adapterName
    if (-not (Test-Path -LiteralPath $adapterPath)) { continue }
    $content = Get-Content -LiteralPath $adapterPath -Raw
    if ($content -match '&\s+[^\r\n]+\s+@arguments\b') {
        $record = [pscustomobject]@{
            File = $adapterPath
            Line = 0
            Column = 0
            Message = 'Adapter uses array splatting for named parameters; use a hashtable splat instead.'
        }
        [void]$failures.Add($record)
        Write-Host ("[FAIL] {0} {1}" -f $adapterName, $record.Message) -ForegroundColor Red
    } else {
        Write-Host ("[PASS] {0} named parameter forwarding" -f $adapterName) -ForegroundColor Green
    }
}

if ($failures.Count -gt 0) {
    throw "PowerShell validation failed with $($failures.Count) error(s)."
}

Write-Host "Validated $($files.Count) PowerShell files and adapter forwarding." -ForegroundColor Cyan
