[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$WarnOnly
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

$warnAt = 400
$failAt = 500

$productionExtensions = @(
    '.dart',
    '.kt',
    '.kts',
    '.ps1',
    '.rs',
    '.swift',
    '.yaml',
    '.yml'
)

$ignoredPathPatterns = @(
    '(^|/)\.git/',
    '(^|/)\.dart_tool/',
    '(^|/)\.gradle/',
    '(^|/)\.torchat/',
    '(^|/)build/',
    '(^|/)target/',
    '(^|/)node_modules/',
    '(^|/)vendor/',
    '(^|/)migrations/',
    '(^|/)sql/migrations/',
    '(^|/)generated/',
    '\.g\.dart$',
    'Cargo\.lock$'
)

$testPathPatterns = @(
    '(^|/)test/',
    '(^|/)tests/',
    '(^|/)androidTest/',
    '(^|/)test_driver/',
    '_test\.dart$'
)

# Existing oversized files are explicit debt. They may shrink, but they may not
# grow while the refactor is in progress.
$oversizedBaselines = @{
    'common/torchat-client-engine/src/actor/mod.rs' = 5399
    'common/torchat-client-engine/src/actor/connection.rs' = 503
    'common/torchat-client-engine/src/peer/inbound.rs' = 521
    'common/torchat-client-engine/src/peer/outbound.rs' = 504
    'common/torchat-client-engine/src/peer/session.rs' = 546
    'common/torchat-client-engine/src/relay/actor.rs' = 1067
    'common/torchat-client-engine/src/storage/runtime_storage.rs' = 1609
    'common/torchat-client-engine/src/storage/sqlite/mod.rs' = 3161
    'common/torchat-client-runtime/src/models.rs' = 733
    'common/torchat-client-runtime/src/pairing_rules.rs' = 773
    'common/torchat-client-runtime/src/runtime.rs' = 3135
    'common/torchat-core/src/peer_protocol.rs' = 665
    'common/torchat-core/src/relay.rs' = 506
    'mobile/android/app/src/main/kotlin/org/torchat/mobile/MainActivity.kt' = 517
    'mobile/lib/features/chats/release_chat_view.dart' = 1124
    # Bounded lifecycle disposal/focus state added during R2; refactor remains
    # tracked by the ratchet and cannot grow beyond this new baseline.
    'mobile/lib/app/app_controller_base.dart' = 958
    'mobile/lib/app/sequential_app_controller.dart' = 602
    'mobile/lib/app/theme/families/retro_theme.dart' = 722
    'mobile/lib/features/chats/chats_view.dart' = 1031
    'mobile/lib/features/contacts/contacts_view.dart' = 640
    'mobile/lib/features/onboarding/onboarding_views.dart' = 535
    'mobile/lib/features/shell/desktop/desktop_workspace.dart' = 706
    'mobile/lib/core/models/domain.dart' = 1052
    'mobile/android/app/src/main/kotlin/org/torchat/mobile/TorChatForegroundService.kt' = 1039
    'mobile/lib/core/runtime/runtime_repository.dart' = 875
    'mobile/lib/main.dart' = 709
    'mobile/lib/windows_runtime.dart' = 619
    'scripts/zip.ps1' = 753
    'server/torchat-server/src/main.rs' = 1821
    'tools/torchat-contract-gen/src/main.rs' = 860
}

function Convert-ToRepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $relative = [IO.Path]::GetRelativePath($RepositoryRoot, $fullPath)
    return $relative.Replace('\', '/')
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

function Get-LineCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    $reader = [IO.File]::OpenText($Path)
    try {
        $count = 0
        while ($null -ne $reader.ReadLine()) {
            $count++
        }
        return $count
    }
    finally {
        $reader.Dispose()
    }
}

$tracked = @(git -C $RepositoryRoot ls-files)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list tracked files for source-size check.'
}
$untracked = @(git -C $RepositoryRoot ls-files --others --exclude-standard)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list untracked files for source-size check.'
}
$sourceFiles = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
foreach ($relativeRaw in ($tracked + $untracked)) {
    if ([string]::IsNullOrWhiteSpace($relativeRaw)) {
        continue
    }
    [void]$sourceFiles.Add($relativeRaw.Replace('\', '/'))
}

$warnings = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
$seenBaselines = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

foreach ($relative in $sourceFiles) {
    if (Test-AnyPattern -Value $relative -Patterns $ignoredPathPatterns) {
        continue
    }

    $extension = [IO.Path]::GetExtension($relative)
    if ($productionExtensions -notcontains $extension) {
        continue
    }

    $path = Join-Path $RepositoryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }

    $lineCount = Get-LineCount -Path $path
    $isTest = Test-AnyPattern -Value $relative -Patterns $testPathPatterns
    $hasBaseline = $oversizedBaselines.ContainsKey($relative)
    if ($hasBaseline) {
        [void]$seenBaselines.Add($relative)
        $limit = [int]$oversizedBaselines[$relative]
        if ($lineCount -gt $limit) {
            $failures.Add("Oversized baseline grew: $relative has $lineCount lines, baseline limit is $limit.")
        }
        elseif ($lineCount -gt $failAt) {
            $warnings.Add("Existing oversized file: $relative has $lineCount lines; baseline limit is $limit.")
        }
        continue
    }

    if ($isTest) {
        if ($lineCount -gt $failAt) {
            $warnings.Add("Large test file: $relative has $lineCount lines; tests warn but do not fail.")
        }
        continue
    }

    if ($lineCount -gt $failAt) {
        $failures.Add("Production file exceeds $failAt lines without baseline: $relative has $lineCount lines.")
    }
    elseif ($lineCount -gt $warnAt) {
        $warnings.Add("Production file is approaching limit: $relative has $lineCount lines.")
    }
}

foreach ($baseline in $oversizedBaselines.Keys) {
    if (-not $seenBaselines.Contains($baseline)) {
        $warnings.Add("Oversized baseline path is no longer tracked: $baseline. Remove it from check-source-size.ps1 after confirming the refactor.")
    }
}

foreach ($warning in $warnings) {
    Write-Warning $warning
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "ERROR: $failure" -ForegroundColor Red
    }
    if (-not $WarnOnly) {
        throw "Source-size check failed with $($failures.Count) issue(s)."
    }
}

Write-Host "[torchat] source-size check passed with $($warnings.Count) warning(s)."

