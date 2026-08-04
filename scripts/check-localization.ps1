[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$mobileRoot = Join-Path $repoRoot 'mobile'

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) {
    $python = Get-Command python3 -ErrorAction SilentlyContinue
}
if ($null -eq $python) {
    throw 'Python 3 is required to validate localization catalogs.'
}

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if ($null -eq $flutter) {
    throw 'Flutter is required to generate and analyze localization sources.'
}

Invoke-Checked -Command $python.Source `
    -Arguments @('scripts/check_localizations.py') `
    -WorkingDirectory $repoRoot
Invoke-Checked -Command $python.Source `
    -Arguments @('scripts/check_ui_localization.py') `
    -WorkingDirectory $repoRoot
Invoke-Checked -Command $flutter.Source `
    -Arguments @('gen-l10n') `
    -WorkingDirectory $mobileRoot
Invoke-Checked -Command $flutter.Source `
    -Arguments @('analyze') `
    -WorkingDirectory $mobileRoot

Write-Host 'Localization validation completed successfully.'
