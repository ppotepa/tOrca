<#
.SYNOPSIS
Creates a committed, portable TorChat repository and diagnostics snapshot.

.DESCRIPTION
Stages the entire Git worktree, creates an automatic checkpoint commit, gathers
uncapped diagnostics for Docker, Tor, server, Android and desktop, copies the
repository including .git, writes manifests and SHA-256 inventories, and emits
a verified ZIP plus a sidecar SHA-256 file.

Operational secrets, private keys and client databases are intentionally
excluded. The complete .git directory is included as explicitly requested.

.EXAMPLE
.\scripts\zip.ps1

.EXAMPLE
.\scripts\zip.ps1 -DeviceAddress emulator-5554 -CommitMessage "snapshot: P2P investigation"
#>
[CmdletBinding()]
param(
    [ValidateSet('local')]
    [string]$Environment = 'local',
    [string]$DeviceAddress,
    [string]$CommitMessage,
    [string]$OutputDirectory,
    [switch]$AllowMissingAndroid,
    [switch]$AllowMissingDesktop
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

function Assert-LastExitCode {
    param([Parameter(Mandatory = $true)][string]$Message)
    if ($LASTEXITCODE -ne 0) { throw $Message }
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

function Copy-RepositorySnapshot {
    $excludedDirectories = @(
        (Join-Path $repoRoot '.torchat'),
        (Join-Path $repoRoot 'secrets')
    )
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
        $repoRoot,
        $stagedRepository,
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
    & robocopy @arguments | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Repository copy failed with robocopy exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stagedRepository '.git\HEAD'))) {
        throw 'Repository snapshot does not contain .git\HEAD.'
    }
}

function Write-RepositoryMetadata {
    New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null
    Write-Utf8 (Join-Path $metadataRoot 'commit.txt') (Invoke-GitText @('show', '-s', '--format=fuller', 'HEAD'))
    Write-Utf8 (Join-Path $metadataRoot 'branch.txt') (Invoke-GitText @('branch', '--show-current'))
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
        commit = Invoke-GitText @('rev-parse', 'HEAD')
        shortCommit = Invoke-GitText @('rev-parse', '--short=12', 'HEAD')
        commitMessage = Invoke-GitText @('log', '-1', '--pretty=%B')
        environment = $Environment
        deviceAddress = if ($DeviceAddress) { $DeviceAddress } else { $null }
        includesGitDirectory = $true
        logsMode = 'full'
        repositoryCopy = 'working tree immediately after automatic snapshot commit'
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
    $entries = Get-ChildItem -LiteralPath $stagingRoot -Recurse -File -Force |
        Where-Object { $_.FullName -ne $inventoryPath } |
        Sort-Object FullName |
        ForEach-Object {
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $relative = (Get-SnapshotRelativePath $stagingRoot $_.FullName).Replace('\', '/')
            "$hash  $relative"
        }
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
            Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Force |
                Sort-Object FullName |
                ForEach-Object {
                    $entryName = (Get-SnapshotRelativePath $SourceDirectory $_.FullName).Replace('\', '/')
                    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $archive,
                        $_.FullName,
                        $entryName,
                        [IO.Compression.CompressionLevel]::Optimal
                    )
                }
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
        $actualRoot = Invoke-GitText @('rev-parse', '--show-toplevel')
        if ([IO.Path]::GetFullPath($actualRoot).TrimEnd('\') -ne $repoRoot.TrimEnd('\')) {
            throw "Refusing to snapshot unexpected Git root: $actualRoot"
        }
        $unmerged = (& git diff --name-only --diff-filter=U 2>$null | Out-String).TrimEnd()
        Assert-LastExitCode 'Could not inspect the repository for unmerged files.'
        if ($unmerged) { throw "Resolve unmerged files before creating a snapshot:`n$unmerged" }

        & git add --all
        Assert-LastExitCode 'git add --all failed.'
        $message = if ($CommitMessage) {
            $CommitMessage
        } else {
            "snapshot: $timestamp"
        }
        & git commit --allow-empty -m $message
        Assert-LastExitCode 'Automatic snapshot commit failed.'
        $shortCommit = Invoke-GitText @('rev-parse', '--short=12', 'HEAD')
        Write-Host "[torchat] Snapshot commit created: $shortCommit"

        New-Item -ItemType Directory -Force -Path $collectedLogs | Out-Null
        $collectorArguments = @{
            Environment = $Environment
            OutputDirectory = $collectedLogs
            Full = $true
        }
        if ($DeviceAddress) { $collectorArguments.DeviceAddress = $DeviceAddress }
        & (Join-Path $PSScriptRoot 'collect-logs.ps1') @collectorArguments
        if (-not $?) { throw 'Full log collection failed.' }

        $androidLog = Join-Path $collectedLogs 'android-full.log'
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

        Copy-RepositorySnapshot
        Write-RepositoryMetadata
        Write-FileInventory

        $archiveName = "torchat-snapshot-$timestamp-$shortCommit.zip"
        $archivePath = Join-Path $snapshotRoot $archiveName
        New-RepositoryArchive -SourceDirectory $stagingRoot -ArchivePath $archivePath

        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
            $requiredEntries = @(
                'repository/.git/HEAD',
                'snapshot/manifest.json',
                'snapshot/files.sha256',
                'logs/last-run/startup-summary.txt'
            )
            if (-not $AllowMissingAndroid) {
                $requiredEntries += 'logs/last-run/android-full.log'
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
        Write-Host "[torchat] Snapshot ready: $archivePath"
        Write-Host "[torchat] SHA256: $archiveHash"
    } finally {
        Pop-Location
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $systemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemporary.StartsWith($systemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected temporary path: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
