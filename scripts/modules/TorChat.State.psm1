Set-StrictMode -Version Latest

function Get-TorChatSafeStateKey {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-TorChatDeploymentStatePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $root = Join-Path $RepositoryRoot '.torchat\deployment-state'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $key = Get-TorChatSafeStateKey -Value "$Platform-$Target"
    return Join-Path $root "$key.json"
}

function Test-TorChatArtifactDeploymentRequired {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Artifact
    )
    if (-not (Test-Path -LiteralPath $Artifact)) { return $true }
    $hash = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $path = Get-TorChatDeploymentStatePath -RepositoryRoot $RepositoryRoot -Platform $Platform -Target $Target
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    try {
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return $state.artifactHash -ne $hash
    } catch { return $true }
}

function Set-TorChatArtifactDeployed {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Artifact,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $path = Get-TorChatDeploymentStatePath -RepositoryRoot $RepositoryRoot -Platform $Platform -Target $Target
    [pscustomobject]@{
        platform = $Platform
        target = $Target
        artifact = [IO.Path]::GetFullPath($Artifact)
        artifactHash = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        runId = $RunId
        deployedAt = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Clear-TorChatBuildState {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot, [switch]$Artifacts)
    foreach ($path in @(
        (Join-Path $RepositoryRoot '.torchat\build-state'),
        (Join-Path $RepositoryRoot '.torchat\deployment-state')
    )) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    if ($Artifacts) {
        $mobileBuild = Join-Path $RepositoryRoot 'mobile\build'
        if (Test-Path -LiteralPath $mobileBuild) { Remove-Item -LiteralPath $mobileBuild -Recurse -Force }
    }
    [pscustomobject]@{ State = 'Ready'; Code = 'BUILD_STATE_CLEARED'; Message = if ($Artifacts) { 'Build state and mobile artifacts removed' } else { 'Build and deployment caches removed' } }
}

Export-ModuleMember -Function @(
    'Test-TorChatArtifactDeploymentRequired',
    'Set-TorChatArtifactDeployed',
    'Clear-TorChatBuildState'
)
