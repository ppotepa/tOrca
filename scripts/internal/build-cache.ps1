[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-TorChatBuildStateRoot([string]$RepoRoot) {
    Join-Path $RepoRoot '.torchat\build-state'
}

function Get-TorChatBuildStatePath([string]$RepoRoot, [string]$Key) {
    $safeKey = $Key -replace '[^A-Za-z0-9_.-]', '_'
    Join-Path (Get-TorChatBuildStateRoot $RepoRoot) "$safeKey.json"
}

function Get-TorChatRelativePath([string]$BasePath, [string]$Path) {
    $baseUri = [Uri]::new($BasePath)
    $pathUri = [Uri]::new([IO.Path]::GetFullPath($Path))
    [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()) -replace '/', '\'
}

function Get-TorChatInputHash {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$Roots,
        [string[]]$ExtraValues = @()
    )

    $repoFull = [IO.Path]::GetFullPath($RepoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $excludedDirectories = @(
        '.git',
        '.codegraph',
        '.torchat',
        'target',
        'build',
        '.gradle',
        '.kotlin',
        '.dart_tool',
        'ephemeral'
    )
    $records = New-Object System.Collections.Generic.List[string]
    foreach ($root in $Roots) {
        $path = if ([IO.Path]::IsPathRooted($root)) { $root } else { Join-Path $RepoRoot $root }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $files = if (Test-Path -LiteralPath $path -PathType Leaf) {
            @(Get-Item -LiteralPath $path)
        } else {
            @(Get-ChildItem -LiteralPath $path -Recurse -File -Force | Where-Object {
                $relative = Get-TorChatRelativePath $repoFull $_.FullName
                $parts = $relative -split '[\\/]'
                -not @($parts | Where-Object { $excludedDirectories -contains $_ })
            })
        }
        foreach ($file in $files) {
            $relativePath = (Get-TorChatRelativePath $repoFull $file.FullName) -replace '\\', '/'
            $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $records.Add("$relativePath=$fileHash")
        }
    }
    foreach ($value in $ExtraValues) {
        $records.Add("env=$value")
    }
    $payload = [Text.Encoding]::UTF8.GetBytes((@($records | Sort-Object) -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ($sha.ComputeHash($payload) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function Test-TorChatBuildFresh {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string[]]$Artifacts
    )

    foreach ($artifact in $Artifacts) {
        try {
            if (-not (Test-Path -LiteralPath $artifact)) { return $false }
        } catch [System.UnauthorizedAccessException] {
            if (-not [IO.File]::Exists($artifact)) { return $false }
        }
    }
    $statePath = Get-TorChatBuildStatePath $RepoRoot $Key
    if (-not (Test-Path -LiteralPath $statePath)) { return $false }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        return $state.hash -eq $Hash
    } catch {
        return $false
    }
}

function Set-TorChatBuildFresh {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string[]]$Artifacts
    )

    $root = Get-TorChatBuildStateRoot $RepoRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [pscustomobject]@{
        key = $Key
        hash = $Hash
        artifacts = $Artifacts
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-TorChatBuildStatePath $RepoRoot $Key)
}
