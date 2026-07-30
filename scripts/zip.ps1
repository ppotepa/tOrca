<#
.SYNOPSIS
Creates a committed TorChat diagnostics snapshot, optionally with a repository copy.

.DESCRIPTION
Stages the entire Git worktree, creates an automatic checkpoint commit, gathers
diagnostics for the latest recorded run from Docker, Tor, server, Android and
desktop, writes manifests and SHA-256 inventories, and emits a verified ZIP
plus a sidecar SHA-256 file. By default the ZIP contains the tracked source
tree and diagnostics together. Android
bugreport and all historical logs are opt-in because they contain much more
data than is normally needed to diagnose the last run.

Operational secrets, private keys and client databases are intentionally

.EXAMPLE
.\scripts\zip.ps1

.EXAMPLE
.\scripts\zip.ps1 -DeviceAddress emulator-5554 -CommitMessage "snapshot: P2P investigation"

.EXAMPLE
.\scripts\zip.ps1 -AllHistory -IncludeBugreport
#>
[CmdletBinding()]
param(
    [ValidateSet('local')]
    [string]$Environment = 'local',
    [string]$DeviceAddress,
    [string]$CommitMessage,
    [string]$OutputDirectory,
    [switch]$AllowMissingAndroid,
    [switch]$AllowMissingDesktop,
    [switch]$AllHistory,
    [switch]$IncludeBugreport,
    [Alias('IncludeRepository')]
    [switch]$IncludeGit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$snapshotRoot = if ($OutputDirectory) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    Join-Path $repoRoot '.torchat\snapshots'
}
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "torchat-snapshot-$timestamp-$PID"
$stagingRoot = Join-Path $temporaryRoot 'package'
$stagedRepository = Join-Path $stagingRoot 'repository'
$collectedLogs = Join-Path $stagingRoot 'logs\last-run'
$metadataRoot = Join-Path $stagingRoot 'snapshot'
$snapshotSucceeded = $false

function Assert-LastExitCode {
    param([Parameter(Mandatory = $true)][string]$Message)
    if ($LASTEXITCODE -ne 0) { throw $Message }
}

function Write-SnapshotStage {
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Write-Host ''
    Write-Host "[torchat][snapshot][$Number/$Total] $Message" -ForegroundColor Cyan
}

function Write-Utf8 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Value = ''
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
}

function Invoke-GitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $result = (& git @Arguments 2>&1 | Out-String).TrimEnd()
    Assert-LastExitCode "git $($Arguments -join ' ') failed.`n$result"
    $result
}

function Get-SafeGitRemote {
    $remote = (& git remote get-url origin 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) { return $null }
    # Do not put an embedded username/password or token into a diagnostic
    # archive. Keep the host, path and revision information useful instead.
    try {
        $uri = [Uri]$remote
        if ($uri.UserInfo) {
            return ([UriBuilder]$uri).ToString() -replace '^([^:]+://)[^@]+@', '$1'
        }
    } catch {
        # SCP-style remotes (git@github.com:owner/repo.git) are already safe.
    }
    $remote
}

function Assert-RepositoryClean {
    param([Parameter(Mandatory = $true)][string]$Context)
    $dirty = (& git status --porcelain=v1 --untracked-files=all 2>$null | Out-String).TrimEnd()
    Assert-LastExitCode "Could not inspect repository state $Context."
    if ($dirty) {
        throw "Repository changed $Context. Snapshot aborted to avoid mixing code from different commits:`n$dirty"
    }
}

function Get-SnapshotRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $resolvedBase = [IO.Path]::GetFullPath($BasePath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($resolvedBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside snapshot root: $resolvedPath"
    }
    $resolvedPath.Substring($resolvedBase.Length)
}

function Get-SnapshotFileBytes {
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return [double]0 }
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return [double]0 }
    $measure = @( $files | Measure-Object -Property Length -Sum )
    if ($measure.Count -eq 0 -or $null -eq $measure[0].Sum) { return [double]0 }
    [double]$measure[0].Sum
}

function Copy-RepositorySnapshot {
    # Export only committed source files. This excludes ignored build output,
    # caches and local diagnostics that previously caused huge snapshots.
    New-Item -ItemType Directory -Force -Path $stagedRepository | Out-Null
    $sourceArchive = Join-Path $temporaryRoot 'source.zip'
    & git archive --format=zip --output=$sourceArchive HEAD
    Assert-LastExitCode 'git archive failed.'
    Expand-Archive -LiteralPath $sourceArchive -DestinationPath $stagedRepository -Force
    Remove-Item -LiteralPath $sourceArchive -Force -ErrorAction SilentlyContinue

    if (-not $IncludeGit) { return }

    # .git is optional and copied separately because git archive excludes it.
    $excludedDirectories = @(
        (Join-Path $repoRoot '.torchat'),
        (Join-Path $repoRoot 'secrets')
    )
    # These are local diagnostic scratch directories. They are not source
    # code and may contain ACL-protected JVM artifacts that make robocopy
    # report a partial failure for an otherwise valid repository snapshot.
    $excludedDirectories += @(Get-ChildItem -LiteralPath $repoRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.tmp-*' } |
        Select-Object -ExpandProperty FullName)
    if ($snapshotRoot.StartsWith(
        $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $excludedDirectories += $snapshotRoot
    }
    $excludedFiles = @(
        '.env',
        '.env.*',
        '*.keystore',
        '*.jks',
        'identity.key',
        'hs_ed25519_secret_key',
        'control_auth_cookie',
        '*.db',
        '*.db-shm',
        '*.db-wal',
        '*.sqlite',
        '*.sqlite3'
    )

    New-Item -ItemType Directory -Force -Path $stagedRepository | Out-Null
    $arguments = @(
        (Join-Path $repoRoot '.git'),
        (Join-Path $stagedRepository '.git'),
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/XJ',
        '/R:2',
        '/W:1',
        '/NP',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/XD'
    ) + $excludedDirectories + @('/XF') + $excludedFiles
    $copyStartedAt = Get-Date
    $nextSizeRefresh = 0
    [double]$copiedBytes = 0
    $robocopyLogPath = Join-Path $temporaryRoot 'robocopy.log'
    $copyJob = Start-Job -ScriptBlock {
        param([object[]]$RobocopyArguments, [string]$LogPath)
        & robocopy @RobocopyArguments 2>&1 | Tee-Object -FilePath $LogPath
        $LASTEXITCODE
    } -ArgumentList (,$arguments), $robocopyLogPath
    try {
        while ($copyJob.State -in @('NotStarted', 'Running')) {
            $elapsed = [int]((Get-Date) - $copyStartedAt).TotalSeconds
            if ($elapsed -ge $nextSizeRefresh) {
                $copiedBytes = Get-SnapshotFileBytes $stagedRepository
                $nextSizeRefresh = $elapsed + 10
            }
            $copiedGiB = [Math]::Round(([double]$copiedBytes / 1GB), 2)
            Write-Progress -Activity 'TorChat snapshot' `
                -Status "Copying .git metadata: ${copiedGiB} GiB copied, ${elapsed}s elapsed" `
                -PercentComplete -1
            if ($elapsed -gt 0 -and ($elapsed % 10) -eq 0) {
                Write-Host "[torchat][snapshot] .git copy is running: ${copiedGiB} GiB, ${elapsed}s."
            }
            Wait-Job -Job $copyJob -Timeout 2 | Out-Null
        }
        $copyExitCode = @(Receive-Job -Job $copyJob)[-1]
    } finally {
        Write-Progress -Activity 'TorChat snapshot' -Completed
        Remove-Job -Job $copyJob -Force -ErrorAction SilentlyContinue
    }
    if ($copyExitCode -ge 8) {
        $details = if (Test-Path -LiteralPath $robocopyLogPath) {
            (Get-Content -LiteralPath $robocopyLogPath | Select-Object -Last 80) -join [Environment]::NewLine
        } else {
            'robocopy diagnostic log was not created'
        }
        throw "Repository copy failed with robocopy exit code $copyExitCode.`n$details"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stagedRepository '.git\HEAD'))) {
        throw 'Repository snapshot does not contain .git\HEAD.'
    }
}

function Write-RepositoryMetadata {
    New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null
    $gitRemote = Get-SafeGitRemote
    $remoteForFile = if ([string]::IsNullOrWhiteSpace($gitRemote)) { '(no origin remote configured)' } else { $gitRemote }
    Write-Utf8 (Join-Path $metadataRoot 'commit.txt') (Invoke-GitText @('show', '-s', '--format=fuller', 'HEAD'))
    Write-Utf8 (Join-Path $metadataRoot 'branch.txt') (Invoke-GitText @('branch', '--show-current'))
    Write-Utf8 (Join-Path $metadataRoot 'git-remote.txt') $remoteForFile
    $restoreInstructions = if ([string]::IsNullOrWhiteSpace($gitRemote)) {
        @(
            'No origin remote is configured in this checkout.'
            "git checkout $(Invoke-GitText @('rev-parse', 'HEAD'))"
        )
    } else {
        @(
            "git clone $gitRemote torchat"
            'cd torchat'
            "git checkout $(Invoke-GitText @('rev-parse', 'HEAD'))"
        )
    }
    Write-Utf8 (Join-Path $metadataRoot 'restore-source.txt') ($restoreInstructions -join [Environment]::NewLine)
    Write-Utf8 (Join-Path $metadataRoot 'status.txt') (Invoke-GitText @('status', '--short', '--branch'))
    Write-Utf8 (Join-Path $metadataRoot 'recent-commits.txt') (Invoke-GitText @('log', '-n', '50', '--date=iso-strict', '--pretty=fuller'))
    Write-Utf8 (Join-Path $metadataRoot 'submodules.txt') (Invoke-GitText @('submodule', 'status', '--recursive'))

    $newestLogs = @(Get-ChildItem -LiteralPath $collectedLogs -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 100 |
        ForEach-Object {
            "{0:o}`t{1}`t{2}" -f $_.LastWriteTimeUtc, $_.Length, (Get-SnapshotRelativePath $collectedLogs $_.FullName)
        })
    Write-Utf8 (Join-Path $metadataRoot 'newest-log-files.txt') ($newestLogs -join [Environment]::NewLine)

    $manifest = [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
        repository = $repoRoot
        branch = Invoke-GitText @('branch', '--show-current')
        gitRemote = $gitRemote
        commit = Invoke-GitText @('rev-parse', 'HEAD')
        shortCommit = Invoke-GitText @('rev-parse', '--short=12', 'HEAD')
        commitMessage = Invoke-GitText @('log', '-1', '--pretty=%B')
        environment = $Environment
        deviceAddress = if ($DeviceAddress) { $DeviceAddress } else { $null }
        includesGitDirectory = $IncludeGit
        logsMode = if ($AllHistory) { 'all-history' } else { 'latest-run' }
        includeBugreport = $IncludeBugreport
        repositoryCopy = 'tracked source tree from the checkpoint commit'
        excludedOperationalData = @(
            '.torchat (logs are included separately; client keys, databases and runtime environment are excluded)',
            'secrets',
            '.env and .env.*',
            '*.keystore and *.jks',
            'identity.key',
            'hs_ed25519_secret_key',
            'control_auth_cookie',
            '*.db, *.sqlite and sidecars'
        )
    }
    Write-Utf8 (Join-Path $metadataRoot 'manifest.json') ($manifest | ConvertTo-Json -Depth 5)
}

function Write-FileInventory {
    $inventoryPath = Join-Path $metadataRoot 'files.sha256'
    $files = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -File -Force |
        Where-Object { $_.FullName -ne $inventoryPath } |
        Sort-Object FullName)
    $entries = [Collections.Generic.List[string]]::new()
    $totalBytes = if ($files.Count -gt 0) {
        [double]((@($files | Measure-Object -Property Length -Sum))[0].Sum)
    } else {
        [double]0
    }
    [double]$processedBytes = 0
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        $relative = (Get-SnapshotRelativePath $stagingRoot $file.FullName).Replace('\', '/')
        $percent = if ($totalBytes -gt 0) {
            [Math]::Min(99, [int](100 * $processedBytes / $totalBytes))
        } else {
            100
        }
        Write-Progress -Activity 'TorChat snapshot' `
            -Status "Hashing $($index + 1)/$($files.Count): $relative" `
            -PercentComplete $percent
        if ($index -eq 0 -or (($index + 1) % 250) -eq 0) {
            Write-Host "[torchat][snapshot] Hashing file $($index + 1)/$($files.Count) ($percent%)."
        }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $entries.Add("$hash  $relative")
        $processedBytes += $file.Length
    }
    Write-Progress -Activity 'TorChat snapshot' -Completed
    Write-Utf8 $inventoryPath ($entries -join [Environment]::NewLine)
}

function New-RepositoryArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archiveStream = [IO.File]::Open(
        $ArchivePath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $archiveStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $true
        )
        try {
            $files = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Force |
                Sort-Object FullName)
            $totalBytes = if ($files.Count -gt 0) {
                [double]((@($files | Measure-Object -Property Length -Sum))[0].Sum)
            } else {
                [double]0
            }
            [double]$processedBytes = 0
            for ($index = 0; $index -lt $files.Count; $index++) {
                    $file = $files[$index]
                    $entryName = (Get-SnapshotRelativePath $SourceDirectory $file.FullName).Replace('\', '/')
                    $percent = if ($totalBytes -gt 0) {
                        [Math]::Min(99, [int](100 * $processedBytes / $totalBytes))
                    } else {
                        100
                    }
                    Write-Progress -Activity 'TorChat snapshot' `
                        -Status "Compressing $($index + 1)/$($files.Count): $entryName" `
                        -PercentComplete $percent
                    if ($index -eq 0 -or (($index + 1) % 250) -eq 0) {
                        $archiveSizeGiB = [Math]::Round(([double]$archiveStream.Length / 1GB), 2)
                        Write-Host "[torchat][snapshot] Compressing file $($index + 1)/$($files.Count) ($percent%); ZIP is ${archiveSizeGiB} GiB."
                    }
                    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $archive,
                        $file.FullName,
                        $entryName,
                        [IO.Compression.CompressionLevel]::Optimal
                    )
                    $processedBytes += $file.Length
            }
            Write-Progress -Activity 'TorChat snapshot' -Completed
        } finally {
            $archive.Dispose()
        }
    } finally {
        $archiveStream.Dispose()
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Missing required tool: git' }
if (-not (Get-Command robocopy -ErrorAction SilentlyContinue)) { throw 'Missing required tool: robocopy' }

New-Item -ItemType Directory -Force -Path $temporaryRoot, $snapshotRoot | Out-Null
try {
    Push-Location $repoRoot
    try {
        Write-SnapshotStage 1 8 'Validating repository state...'
        $actualRoot = Invoke-GitText @('rev-parse', '--show-toplevel')
        if ([IO.Path]::GetFullPath($actualRoot).TrimEnd('\') -ne $repoRoot.TrimEnd('\')) {
            throw "Refusing to snapshot unexpected Git root: $actualRoot"
        }
        $unmerged = (& git diff --name-only --diff-filter=U 2>$null | Out-String).TrimEnd()
        Assert-LastExitCode 'Could not inspect the repository for unmerged files.'
        if ($unmerged) { throw "Resolve unmerged files before creating a snapshot:`n$unmerged" }

        Write-SnapshotStage 2 8 'Creating or reusing the checkpoint commit...'
        $pendingChanges = (& git status --porcelain=v1 --untracked-files=all 2>$null | Out-String).TrimEnd()
        Assert-LastExitCode 'Could not inspect pending repository changes.'
        if ($pendingChanges) {
            & git add --all
            Assert-LastExitCode 'git add --all failed.'
            $message = if ($CommitMessage) {
                $CommitMessage
            } else {
                "snapshot: $timestamp"
            }
            & git commit -m $message
            Assert-LastExitCode 'Automatic snapshot commit failed.'
        } else {
            Write-Host '[torchat] Worktree is already clean; reusing the current checkpoint commit.'
        }
        $shortCommit = Invoke-GitText @('rev-parse', '--short=12', 'HEAD')
        Assert-RepositoryClean 'immediately after the checkpoint commit'
        Write-Host "[torchat] Snapshot commit created: $shortCommit"

        Write-SnapshotStage 3 8 'Collecting uncapped Docker, Android and desktop diagnostics...'
        New-Item -ItemType Directory -Force -Path $collectedLogs | Out-Null
        $collectorArguments = @{
            Environment = $Environment
            OutputDirectory = $collectedLogs
            Full = $true
        }
        if ($DeviceAddress) { $collectorArguments.DeviceAddress = $DeviceAddress }
        if ($AllHistory) { $collectorArguments.AllHistory = $true }
        if ($IncludeBugreport) { $collectorArguments.IncludeBugreport = $true }
        & (Join-Path $PSScriptRoot 'collect-logs.ps1') @collectorArguments
        if (-not $?) { throw 'Full log collection failed.' }

        Write-SnapshotStage 4 8 'Validating required diagnostic sources...'
        $androidLog = Join-Path $collectedLogs 'android-app.log'
        if (-not $AllowMissingAndroid) {
            if (-not (Test-Path -LiteralPath $androidLog)) {
                throw 'Android logs are missing. Connect a device or use -AllowMissingAndroid explicitly.'
            }
            $androidContents = Get-Content -LiteralPath $androidLog -Raw -ErrorAction SilentlyContinue
            if (-not $androidContents -or $androidContents -match '^No connected ADB device found') {
                throw 'No connected Android device was captured. Connect it or use -AllowMissingAndroid explicitly.'
            }
        }
        if (-not $AllowMissingDesktop -and -not (Test-Path -LiteralPath (Join-Path $collectedLogs 'desktop.log'))) {
            throw 'The latest desktop log is missing. Run the desktop app or use -AllowMissingDesktop explicitly.'
        }

        Assert-RepositoryClean 'while diagnostics were being collected'
        Write-SnapshotStage 5 8 $(if ($IncludeGit) { 'Copying tracked source and .git...' } else { 'Copying tracked source tree...' })
        Copy-RepositorySnapshot
        Assert-RepositoryClean 'while the source tree was being copied'
        Write-SnapshotStage 6 8 'Writing snapshot metadata and SHA-256 inventory...'
        Write-RepositoryMetadata
        Write-FileInventory

        Write-SnapshotStage 7 8 'Compressing source and diagnostics...'
        $archiveName = "torchat-snapshot-$timestamp-$shortCommit.zip"
        $archivePath = Join-Path $snapshotRoot $archiveName
        New-RepositoryArchive -SourceDirectory $stagingRoot -ArchivePath $archivePath

        Write-SnapshotStage 8 8 'Verifying archive contents and final checksum...'
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
            $requiredEntries = @(
                'snapshot/manifest.json',
                'snapshot/files.sha256',
                'logs/last-run/startup-summary.txt'
            )
            if ($IncludeGit) {
                $requiredEntries += 'repository/.git/HEAD'
            }
            $requiredEntries += 'repository/Cargo.toml'
            if (-not $AllowMissingAndroid) {
                $requiredEntries += 'logs/last-run/android-app.log'
            }
            foreach ($requiredEntry in $requiredEntries) {
                if ($entryNames -notcontains $requiredEntry) {
                    throw "Snapshot verification failed: missing $requiredEntry"
                }
            }
        } finally {
            $archive.Dispose()
        }

        $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Utf8 "$archivePath.sha256" "$archiveHash  $archiveName"
        $snapshotSucceeded = $true
        Write-Host "[torchat] Snapshot ready: $archivePath"
        Write-Host "[torchat] SHA256: $archiveHash"
    } finally {
        Pop-Location
    }
} finally {
    if (-not $snapshotSucceeded) {
        $failedLogs = Join-Path $stagingRoot 'logs\last-run'
        if (Test-Path -LiteralPath $failedLogs) {
            $failedLogsRoot = Join-Path $repoRoot ".torchat\logs\snapshot-failed-$timestamp"
            try {
                New-Item -ItemType Directory -Force -Path $failedLogsRoot | Out-Null
                Copy-Item -LiteralPath $failedLogs -Destination $failedLogsRoot -Recurse -Force
                Write-Host "[torchat] Failed snapshot logs preserved in: $failedLogsRoot" -ForegroundColor Yellow
            } catch {
                Write-Warning "Could not preserve failed snapshot logs: $($_.Exception.Message)"
            }
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $systemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemporary.StartsWith($systemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected temporary path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
