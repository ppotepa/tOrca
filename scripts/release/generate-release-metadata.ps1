[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ArtifactRoot,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $releaseSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'release/version.json') -Raw |
        ConvertFrom-Json
    $ArtifactRoot = Join-Path $RepositoryRoot ".torca/artifacts/$($releaseSource.version)"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot '.torca/release/metadata'
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$release = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'release/version.json') -Raw |
    ConvertFrom-Json
$commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw 'Unable to resolve release commit.'
}
$utf8 = [Text.UTF8Encoding]::new($false)

function Invoke-JsonCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )
    if (-not (Get-Command $Executable -ErrorAction SilentlyContinue)) {
        throw "Required executable is unavailable: $Executable"
    }
    Push-Location $WorkingDirectory
    try {
        $text = (& $Executable @Arguments 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "$Executable exited with code $LASTEXITCODE`n$text"
        }
        return $text | ConvertFrom-Json
    } finally {
        Pop-Location
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 12
    )
    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth $Depth),
        $utf8
    )
}

$cargo = Invoke-JsonCommand cargo @('metadata', '--locked', '--format-version', '1') $RepositoryRoot
$components = [System.Collections.Generic.List[object]]::new()
foreach ($package in $cargo.packages) {
    $properties = [System.Collections.Generic.List[object]]::new()
    $properties.Add([pscustomobject][ordered]@{
        name = 'torca:ecosystem'
        value = 'cargo'
    })
    if ($package.source) {
        $properties.Add([pscustomobject][ordered]@{
            name = 'torca:source'
            value = $package.source
        })
    }
    $component = [ordered]@{
        type = 'library'
        name = $package.name
        version = $package.version
        properties = @($properties)
    }
    if ($package.license) {
        $component['licenses'] = @([ordered]@{ expression = $package.license })
    }
    $components.Add([pscustomobject]$component)
}

$flutterInventories = [System.Collections.Generic.List[object]]::new()
foreach ($relative in @('apps/mobile/flutter', 'apps/desktop/flutter')) {
    $root = Join-Path $RepositoryRoot $relative
    $inventory = Invoke-JsonCommand flutter @('pub', 'deps', '--json') $root
    $flutterInventories.Add([pscustomobject][ordered]@{
        application = $relative
        packages = @($inventory.packages)
    })
    foreach ($package in $inventory.packages) {
        $components.Add([pscustomobject][ordered]@{
            type = 'library'
            name = $package.name
            version = if ($package.version) { $package.version } else { 'path' }
            properties = @(
                [ordered]@{ name = 'torca:ecosystem'; value = 'pub' },
                [ordered]@{ name = 'torca:application'; value = $relative }
            )
        })
    }
}

$deduplicated = @(
    $components |
        Group-Object { "$($_.properties[0].value):$($_.name):$($_.version)" } |
        ForEach-Object { $_.Group | Select-Object -First 1 } |
        Sort-Object name, version
)
$sbom = [ordered]@{
    bomFormat = 'CycloneDX'
    specVersion = '1.6'
    serialNumber = "urn:uuid:$([guid]::NewGuid())"
    version = 1
    metadata = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
        component = [ordered]@{
            type = 'application'
            name = $release.product
            version = $release.version
            properties = @(
                [ordered]@{ name = 'torca:build'; value = $release.build.ToString() },
                [ordered]@{ name = 'torca:channel'; value = $release.channel },
                [ordered]@{ name = 'torca:commit'; value = $commit }
            )
        }
    }
    components = $deduplicated
}
$sbomPath = Join-Path $OutputDirectory "torca-$($release.version)-sbom.cdx.json"
Write-JsonFile -Value $sbom -Path $sbomPath

$flutterPath = Join-Path $OutputDirectory "torca-$($release.version)-flutter-inventory.json"
Write-JsonFile -Value @($flutterInventories) -Path $flutterPath

$artifactEntries = [System.Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $ArtifactRoot -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $ArtifactRoot -File -Recurse | Sort-Object FullName) {
        $artifactEntries.Add([pscustomobject][ordered]@{
            path = [IO.Path]::GetRelativePath($ArtifactRoot, $file.FullName).Replace('\', '/')
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
}
$checksumsPath = Join-Path $OutputDirectory "torca-$($release.version)-checksums.json"
$checksums = [ordered]@{
    schema = 1
    product = $release.product
    version = $release.version
    build = [int]$release.build
    commit = $commit
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    artifacts = @($artifactEntries)
}
Write-JsonFile -Value $checksums -Path $checksumsPath -Depth 8

Write-Host "Torca SBOM: $sbomPath"
Write-Host "Torca Flutter inventory: $flutterPath"
Write-Host "Torca checksums: $checksumsPath"
