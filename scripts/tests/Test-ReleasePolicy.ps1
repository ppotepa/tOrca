[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$checker = Join-Path $repoRoot 'scripts\internal\check-release-policy.ps1'
$workflow = Join-Path $repoRoot '.github\workflows\release-0-1-validation.yml'
$deny = Join-Path $repoRoot 'deny.toml'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("torchat-policy-" + [guid]::NewGuid())

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $mutated = Join-Path $tempRoot 'workflow.yml'
    (Get-Content -LiteralPath $workflow -Raw).Replace(
        'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683',
        'actions/checkout@v4'
    ) | Set-Content -LiteralPath $mutated -NoNewline

    $failedAsExpected = $false
    try {
        & $checker -WorkflowPath $mutated -DenyPath $deny | Out-Null
    } catch {
        $failedAsExpected = $_.Exception.Message -match 'unpinned actions'
    }
    if (-not $failedAsExpected) {
        throw 'Policy checker did not reject the intentionally unpinned action.'
    }
    Write-Output 'Release policy negative test passed.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
