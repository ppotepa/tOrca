Set-StrictMode -Version Latest

function Get-TorChatRepositoryRoot {
    param([Parameter(Mandatory = $true)][string]$ScriptRoot)
    return (Split-Path -Parent $ScriptRoot)
}

function Read-TorChatEnvironmentFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Environment manifest is missing: $Path" }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { continue }
        $values[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
    return $values
}

function Get-TorChatEnvironmentPaths {
    param([Parameter(Mandatory = $true)][string]$RepoRoot, [Parameter(Mandatory = $true)][ValidateSet('local','staging','production')][string]$Environment)
    $manifest = Join-Path $RepoRoot "infra\environments\$Environment.env"
    $runtime = Join-Path $RepoRoot ".torchat\runtime\$Environment"
    [pscustomobject]@{
        Manifest = $manifest
        RuntimeDirectory = $runtime
        RuntimeEnvironment = Join-Path $runtime "environment.env"
    }
}

function Ensure-TorChatEnvironment {
    param([Parameter(Mandatory = $true)][string]$RepoRoot, [Parameter(Mandatory = $true)][ValidateSet('local','staging','production')][string]$Environment)
    $paths = Get-TorChatEnvironmentPaths $RepoRoot $Environment
    if (-not (Test-Path -LiteralPath $paths.Manifest)) {
        $example = "$($paths.Manifest).example"
        throw "Environment '$Environment' is not configured. Create $($paths.Manifest) from $example."
    }
    $values = Read-TorChatEnvironmentFile $paths.Manifest
    New-Item -ItemType Directory -Force -Path $paths.RuntimeDirectory | Out-Null
    if ($Environment -eq 'local') {
        if (-not $values['TORCHAT_COMPOSE_PROJECT']) { $values['TORCHAT_COMPOSE_PROJECT'] = 'torchat-local' }
        if (-not $values['TORCHAT_HTTP_PORT']) { $values['TORCHAT_HTTP_PORT'] = '8080' }
        if (-not $values['TORCHAT_SOCKS_PORT']) { $values['TORCHAT_SOCKS_PORT'] = '9050' }
    }
    if (Test-Path -LiteralPath $paths.RuntimeEnvironment) {
        # The manifest owns stable behaviour (ports, profile and project
        # name). Runtime state owns only generated or secret values.
        foreach ($pair in (Read-TorChatEnvironmentFile $paths.RuntimeEnvironment).GetEnumerator()) {
            if ($pair.Key -in @('TORCHAT_ONION_URL')) {
                $values[$pair.Key] = $pair.Value
            }
        }
    }
    $values['TORCHAT_ENVIRONMENT'] = $Environment
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lines = @($values.Keys | Sort-Object | ForEach-Object { "$_=$($values[$_])" })
    [System.IO.File]::WriteAllLines($paths.RuntimeEnvironment, [string[]]$lines, $utf8NoBom)
    return [pscustomobject]@{ Paths = $paths; Values = $values }
}

function Set-TorChatEnvironmentOnion {
    param([Parameter(Mandatory = $true)]$EnvironmentState, [Parameter(Mandatory = $true)][string]$OnionUrl)
    if ($OnionUrl -notmatch '^https?://[a-z2-7]{56}\.onion$') { throw "Invalid v3 onion URL: $OnionUrl" }
    $EnvironmentState.Values['TORCHAT_ONION_URL'] = $OnionUrl
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lines = @($EnvironmentState.Values.Keys | Sort-Object | ForEach-Object { "$_=$($EnvironmentState.Values[$_])" })
    [System.IO.File]::WriteAllLines($EnvironmentState.Paths.RuntimeEnvironment, [string[]]$lines, $utf8NoBom)
}

function Import-TorChatEnvironment {
    param([Parameter(Mandatory = $true)]$EnvironmentState, [switch]$RequireOnion)
    foreach ($pair in $EnvironmentState.Values.GetEnumerator()) { Set-Item -Path "Env:$($pair.Key)" -Value $pair.Value }
    if ($RequireOnion -and $env:TORCHAT_ONION_URL -notmatch '^https?://[a-z2-7]{56}\.onion$') {
        throw "Environment '$($env:TORCHAT_ENVIRONMENT)' has no valid TORCHAT_ONION_URL yet. Run 'torchat env up --environment local' or configure its manifest."
    }
}
