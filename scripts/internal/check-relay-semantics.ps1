[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$roots = @(
    (Join-Path $repoRoot 'mobile\lib'),
    (Join-Path $repoRoot 'protocol')
)
$forbidden = @(
    '(?i)offline\s+delivery',
    '(?i)dostaw(a|y)\s+offline',
    '(?i)dostarcz(on|enie)\s+offline'
)
$matches = foreach ($root in $roots) {
    Get-ChildItem -LiteralPath $root -Recurse -File -Include *.dart,*.md,*.yaml,*.yml |
        Select-String -Pattern $forbidden
}
$matches = $matches | Where-Object {
    $_.Line -notmatch '(?i)must\s+not\s+be\s+described|nie\s+.*offline|bez\s+obietnicy'
}
if ($matches) {
    $details = $matches | ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line.Trim())" }
    throw "Relay UI/protocol contains forbidden offline-delivery promise:`n$($details -join "`n")"
}
Write-Output 'Relay semantics check passed: no offline-delivery promise found in UI/protocol.'
