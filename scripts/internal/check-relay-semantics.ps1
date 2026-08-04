[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$roots = @(
    (Join-Path $repoRoot 'mobile\lib'),
    (Join-Path $repoRoot 'protocol'),
    (Join-Path $repoRoot 'common\torchat-client-engine\src'),
    (Join-Path $repoRoot 'common\torchat-client-runtime\src')
)
$forbidden = @(
    '(?i)offline\s+delivery',
    '(?i)dostaw(a|y)\s+offline',
    '(?i)dostarcz(on|enie)\s+offline'
)
$matches = foreach ($root in $roots) {
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Recurse -File -Include *.dart,*.rs,*.md,*.yaml,*.yml |
        Select-String -Pattern $forbidden
    }
}
$matches = $matches | Where-Object {
    $_.Line -notmatch '(?i)must\s+not\s+be\s+described|nie\s+.*offline|bez\s+obietnicy'
}
if ($matches) {
    $details = $matches | ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line.Trim())" }
    throw "Relay UI/protocol contains forbidden offline-delivery promise:`n$($details -join "`n")"
}
$legacySymbols = @(
    'MessageTransportOutcome::Forwarded',
    'MessageTransportOutcome::RecipientOffline',
    'PeerWithRelayFallback',
    'ContactTransportPolicy::RelayOnly',
    'RelayServerFrame::Forwarded',
    'RelayServerFrame::RecipientOffline'
)
foreach ($symbol in $legacySymbols) {
    $hits = rg -n -F --glob '!**/target/**' $symbol (Join-Path $repoRoot 'common') 2>$null
    if ($hits) { throw "Legacy relay transport symbol remains: $symbol`n$hits" }
}
Write-Output 'Relay semantics check passed: no offline-delivery promise or legacy relay transport symbol found.'
