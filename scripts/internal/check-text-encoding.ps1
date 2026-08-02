[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$sourceExtensions = @(
    '.dart', '.json', '.kt', '.kts', '.md', '.ps1', '.rs', '.sql', '.toml', '.txt', '.yaml', '.yml'
)
$ignoredDirectories = @('.git', '.dart_tool', '.gradle', '.idea', '.torchat', 'build', 'target')
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$failures = [System.Collections.Generic.List[string]]::new()

Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File | Where-Object {
    $sourceExtensions -contains $_.Extension -and
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

Write-Host '[torchat] UTF-8 and mojibake check passed.'
