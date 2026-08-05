[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
}
$serverRoot = Resolve-Path (Join-Path $RepositoryRoot 'services\torchat-relay\src')
$sources = Get-ChildItem -LiteralPath $serverRoot -Recurse -File -Filter '*.rs'
$text = ($sources | Get-Content -Raw) -join "`n"

$badPatterns = @(
    '(?m)tracing::(?:trace|debug|info|warn|error)!\([^\r\n]*\binstallation_id\s*=',
    '(?m)tracing::(?:trace|debug|info|warn|error)!\([^\r\n]*\bmessage_id\s*=',
    '(?m)tracing::(?:trace|debug|info|warn|error)!\([^\r\n]*\bpairing_id\s*='
)
$badPatterns += @(
    '(?m)tracing::(?:trace|debug|info|warn|error)!\([^\r\n]*\bmessage_id_hash\s*=',
    '(?m)tracing::(?:trace|debug|info|warn|error)!\([^\r\n]*(?:sender_hash|sender_alias)[^\r\n]*(?:recipient_hash|recipient_alias)',
    '(?m)tracing::(?:trace|debug|info|warn|error)!\([^\r\n]*(?:recipient_hash|recipient_alias)[^\r\n]*(?:sender_hash|sender_alias)',
    '(?m)\bpseudonymous_id_with_secret\s*\([^\r\n]*pairing',
    '(?m)\blog_secret\s*=\s*.*pairing_secret'
)
foreach ($pattern in $badPatterns) {
    $match = $text | Select-String -Pattern $pattern
    if ($match) {
        throw "Server tracing contains a plaintext identifier field: $($match.Line.Trim())"
    }
}
Write-Output 'Relay log privacy check passed.'
