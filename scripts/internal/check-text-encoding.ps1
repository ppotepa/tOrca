[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$sourceExtensions = @(
    '.dart', '.json', '.kt', '.kts', '.md', '.ps1', '.rs', '.sql', '.toml', '.txt', '.yaml', '.yml'
)
$ignoredDirectories = @('.git', '.dart_tool', '.gradle', '.idea', '.torchat', 'build', 'target', 'findings')
$ignoredFiles = @('concat.txt')
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$failures = [System.Collections.Generic.List[string]]::new()

Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File | Where-Object {
    $sourceExtensions -contains $_.Extension -and
    $ignoredFiles -notcontains $_.Name -and
    ($_.FullName.Split([IO.Path]::DirectorySeparatorChar) | Where-Object {
        $ignoredDirectories -contains $_
    } | Measure-Object | Select-Object -ExpandProperty Count) -eq 0
} | ForEach-Object {
    $path = $_.FullName
    try {
        $text = $utf8.GetString([IO.File]::ReadAllBytes($path))
    }
    catch {
        $failures.Add("Invalid UTF-8: $path")
        return
    }

    # Use code points rather than non-ASCII literals: the checker itself must
    # remain safe to parse in every Windows shell encoding.
    $markers = @(
        [string][char]0xFFFD,
        [string][char]0x00C3,
        [string][char]0x00C2,
        [string]::Concat([char]0x00E2, [char]0x20AC),
        [string]::Concat([char]0x0393, [char]0x00C7),
        [string][char]0x253C
    )
    foreach ($marker in $markers) {
        if ($text.IndexOf($marker, [StringComparison]::Ordinal) -ge 0) {
            $failures.Add("Possible mojibake (U+$([Convert]::ToString([int][char]$marker[0], 16))): $path")
            break
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Text encoding check failed with $($failures.Count) issue(s)."
}

# Keep one cross-language UTF-8 sentinel in the checker. This catches an
# exporter or shell that silently converts Polish text while preserving valid
# UTF-8 byte sequences for ordinary ASCII-only fixtures.
$golden = -join @(
    [char]0x005A, [char]0x0061, [char]0x017C, [char]0x00F3,
    [char]0x0142, [char]0x0107, [char]0x0020, [char]0x0067,
    [char]0x0119, [char]0x015B, [char]0x006C, [char]0x0105,
    [char]0x0020, [char]0x006A, [char]0x0061, [char]0x017A, [char]0x0144
)
$goldenFixtures = @(
    ('{"text":"' + $golden + '"}', 'JSON'),
    ('const text = "' + $golden + '";', 'Dart'),
    ('let text = "' + $golden + '";', 'Rust')
)
foreach ($fixture in $goldenFixtures) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($fixture[0])
    $roundTrip = $utf8.GetString($bytes)
    if ($roundTrip -ne $fixture[0]) {
        throw "UTF-8 golden round-trip failed for $($fixture[1])."
    }
}
$fixturePath = Join-Path $RepositoryRoot 'common/encoding-fixture.json'
if (Test-Path -LiteralPath $fixturePath) {
    $fixtureText = [IO.File]::ReadAllText($fixturePath, $utf8)
    $fixtureObject = $fixtureText | ConvertFrom-Json
    foreach ($property in 'polish', 'emoji', 'combining', 'cyrillic', 'greek') {
        $value = [string]$fixtureObject.$property
        if ([string]::IsNullOrEmpty($value) -or $value -ne ([string]$fixtureObject.$property)) {
            throw "UTF-8 fixture round-trip failed for '$property'."
        }
    }
}

Write-Host '[torchat] UTF-8 and mojibake check passed.'
