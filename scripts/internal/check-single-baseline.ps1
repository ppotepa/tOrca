[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

$sourceRoots = @('apps/', 'common/', 'packages/', 'services/', 'tools/')
$productionExtensions = @('.dart', '.kt', '.kts', '.ps1', '.rs', '.swift')
$ignoredPathPatterns = @(
    '(^|/)\.dart_tool/',
    '(^|/)\.gradle/',
    '(^|/)build/',
    '(^|/)target/',
    '(^|/)node_modules/',
    '(^|/)vendor/',
    '(^|/)generated/',
    '(^|/)migrations/',
    '(^|/)sql/migrations/',
    '(^|/)test/',
    '(^|/)tests/',
    '(^|/)androidTest/',
    '(^|/)test_driver/',
    '_test\.dart$',
    '\.g\.dart$'
)
$forbiddenPathPatterns = @(
    '(^|[/_.-])legacy([/_.-]|$)',
    '(^|[/_.-])deprecated([/_.-]|$)',
    '(^|[/_.-])compat(?:ibility)?([/_.-]|$)',
    '(^|[/_.-])v2([/_.-]|$)'
)
$forbiddenContentPatterns = [ordered]@{
    'dead-code suppression' = '#!?' + '\[allow\(dead_code\)\]'
    'legacy include' = 'include!\s*\(\s*"legacy\.rs"\s*\)'
    'legacy symbol' = '\bLegacy[A-Z][A-Za-z0-9_]*\b'
    'deprecated symbol' = '\bDeprecated[A-Z][A-Za-z0-9_]*\b'
    'compatibility symbol' = '\bCompat(?:ibility)?[A-Z][A-Za-z0-9_]*\b'
    'V2 implementation symbol' = '\b[A-Za-z_][A-Za-z0-9_]*V2\b'
}

function Test-AnyPattern {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string[]]$Patterns
    )
    foreach ($pattern in $Patterns) {
        if ($Value -match $pattern) {
            return $true
        }
    }
    return $false
}

$tracked = @(git -C $RepositoryRoot ls-files)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list tracked files for single-baseline check.'
}

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($relativeRaw in $tracked) {
    $relative = $relativeRaw.Replace('\', '/')
    if (-not ($sourceRoots | Where-Object { $relative.StartsWith($_, [StringComparison]::Ordinal) })) {
        continue
    }
    if (Test-AnyPattern -Value $relative -Patterns $ignoredPathPatterns) {
        continue
    }

    foreach ($pattern in $forbiddenPathPatterns) {
        if ($relative -match $pattern) {
            $failures.Add("Alternative implementation path is forbidden: $relative")
            break
        }
    }

    $extension = [IO.Path]::GetExtension($relative)
    if ($productionExtensions -notcontains $extension) {
        continue
    }
    $path = Join-Path $RepositoryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }
    $content = [IO.File]::ReadAllText($path)
    foreach ($entry in $forbiddenContentPatterns.GetEnumerator()) {
        if ($content -match $entry.Value) {
            $failures.Add("Forbidden $($entry.Key) in $relative")
        }
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "ERROR: $failure" -ForegroundColor Red
    }
    throw "Single-baseline check failed with $($failures.Count) issue(s)."
}

Write-Host '[torchat] single-baseline check passed.'
