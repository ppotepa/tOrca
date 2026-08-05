[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$arbRoot = Join-Path $repoRoot 'apps\mobile\flutter\lib\locales\resources'
$english = Get-Content (Join-Path $arbRoot 'app_en.arb') -Raw | ConvertFrom-Json
$polish = Get-Content (Join-Path $arbRoot 'app_pl.arb') -Raw | ConvertFrom-Json

$englishKeys = @($english.PSObject.Properties.Name | Where-Object { $_ -notlike '@*' } | Sort-Object)
$polishKeys = @($polish.PSObject.Properties.Name | Where-Object { $_ -notlike '@*' } | Sort-Object)
if ((Compare-Object $englishKeys $polishKeys).Count -ne 0) {
    throw 'English and Polish ARB files do not have identical message keys.'
}

foreach ($key in $englishKeys) {
    $englishMeta = $english.PSObject.Properties["@$key"].Value
    $polishMeta = $polish.PSObject.Properties["@$key"].Value
    $englishPlaceholders = @()
    $polishPlaceholders = @()
    if ($null -ne $englishMeta -and $null -ne $englishMeta.placeholders) {
        $englishPlaceholders = @($englishMeta.placeholders.PSObject.Properties.Name | Sort-Object)
    }
    if ($null -ne $polishMeta -and $null -ne $polishMeta.placeholders) {
        $polishPlaceholders = @($polishMeta.placeholders.PSObject.Properties.Name | Sort-Object)
    }
    if ((Compare-Object $englishPlaceholders $polishPlaceholders).Count -ne 0) {
        throw "Placeholder mismatch for ARB key '$key'."
    }
}

$forbiddenPattern = '["''](Nowa wiadomość|Nowe zaproszenie)["'']'
$productionRoots = @(
    (Join-Path $repoRoot 'apps\mobile\flutter\lib'),
    (Join-Path $repoRoot 'apps\mobile\flutter\android\app\src\main\kotlin'),
    (Join-Path $repoRoot 'packages\torchat-client-engine\src')
)
foreach ($root in $productionRoots) {
    foreach ($match in (Get-ChildItem $root -Recurse -File | Select-String -Pattern $forbiddenPattern)) {
        if ($match.Path -notmatch '\\locales\\resources\\|\\values(-[^\\]+)?\\strings\.xml$') {
            throw "Legacy notification text found in production code: $($match.Path):$($match.LineNumber)"
        }
    }
}

Write-Output 'Localization checks passed.'
