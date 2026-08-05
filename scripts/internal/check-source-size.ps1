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
    # Frozen compatibility snapshot retained while the active engine uses the
    # split unified actor modules. New production code must not be added here.
    '^packages/torchat-client-engine/src/actor/legacy(?:\.rs|/)',
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
    'packages/torchat-client-engine/src/actor/connection.rs' = 503
    'packages/torchat-client-engine/src/actor/peer_events.rs' = 511
    'packages/torchat-peer/src/peer/inbound.rs' = 521
    'packages/torchat-peer/src/peer/outbound.rs' = 504
    'packages/torchat-peer/src/peer/session.rs' = 546
    'packages/torchat-client-engine/src/relay/actor.rs' = 1067
    'packages/torchat-storage/src/storage/runtime_storage.rs' = 1609
    'packages/torchat-storage/src/storage/sqlite/mod.rs' = 3161
    'packages/torchat-runtime/src/models.rs' = 751
    'packages/torchat-runtime/src/pairing_rules.rs' = 781
    'packages/torchat-runtime/src/runtime/pairing_process.rs' = 715
    'packages/torchat-runtime/src/runtime.rs' = 3135
    'common/torchat-core/src/peer_protocol.rs' = 665
    'packages/torchat-crypto/src/mls.rs' = 731
    'common/torchat-core/src/relay.rs' = 541
    'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/MainActivity.kt' = 525
    'apps/mobile/flutter/lib/features/chats/release_chat_view.dart' = 1124
    # Bounded lifecycle disposal/focus state added during R2; refactor remains
    # tracked by the ratchet and cannot grow beyond this new baseline.
    'apps/mobile/flutter/lib/app/app_controller_base.dart' = 958
    'apps/mobile/flutter/lib/app/sequential_app_controller.dart' = 602
    'packages/torchat-flutter-ui/lib/theme/families/retro_theme.dart' = 722
    'apps/mobile/flutter/lib/features/account/settings_view.dart' = 524
    'apps/mobile/flutter/lib/features/contacts/contacts_view.dart' = 765
    'apps/mobile/flutter/lib/features/onboarding/onboarding_views.dart' = 572
    'apps/mobile/flutter/lib/platform/desktop/desktop_workspace.dart' = 807
    'packages/torchat-flutter-ui/lib/core/models/domain.dart' = 1052
    'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/TorChatForegroundService.kt' = 1039
    'apps/mobile/flutter/lib/core/runtime/runtime_repository.dart' = 875
    'apps/mobile/flutter/lib/main.dart' = 738
    'apps/desktop/flutter/lib/platform/desktop/windows_runtime.dart' = 701
    'scripts/zip.ps1' = 753
    'services/torchat-relay/src/main.rs' = 687
    'apps/desktop/native/src/runtime_engine_stdio.rs' = 594
    'tools/torchat-contract-gen/src/main.rs' = 861
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
