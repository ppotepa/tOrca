Set-StrictMode -Version Latest

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
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][ValidateSet('local','staging','production')][string]$Environment
    )
    $runtimeDirectory = Join-Path $RepositoryRoot ".torchat\runtime\$Environment"
    [pscustomobject]@{
        Manifest = Join-Path $RepositoryRoot "infra\environments\$Environment.env"
        RuntimeDirectory = $runtimeDirectory
        RuntimeEnvironment = Join-Path $runtimeDirectory 'environment.env'
    }
}

function New-TorChatSecret {
    param([ValidateRange(16, 128)][int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($buffer).Replace('+','A').Replace('/','B').Replace('=','')
}

function Save-TorChatEnvironmentState {
    param([Parameter(Mandatory = $true)]$EnvironmentState)
    New-Item -ItemType Directory -Force -Path $EnvironmentState.Paths.RuntimeDirectory | Out-Null
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $lines = @($EnvironmentState.Values.Keys | Sort-Object | ForEach-Object { "$_=$($EnvironmentState.Values[$_])" })
    $content = (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    $path = [string]$EnvironmentState.Paths.RuntimeEnvironment
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = [IO.File]::ReadAllText($path, $utf8NoBom)
            if ($existing -eq $content) { return }
        } catch {
            # Fall through to the guarded write path below.
        }
    }
    $attempts = 0
    while ($true) {
        try {
            [IO.File]::WriteAllText($path, $content, $utf8NoBom)
            return
        } catch [System.IO.IOException] {
            $attempts += 1
            if ($attempts -ge 5) { throw }
            Start-Sleep -Milliseconds (40 * $attempts)
        }
    }
}

function Get-TorChatEnvironmentState {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][ValidateSet('local','staging','production')][string]$Environment
    )

    $paths = Get-TorChatEnvironmentPaths -RepositoryRoot $RepositoryRoot -Environment $Environment
    if (-not (Test-Path -LiteralPath $paths.Manifest)) {
        throw "Environment '$Environment' is not configured. Create $($paths.Manifest) from $($paths.Manifest).example."
    }

    $values = Read-TorChatEnvironmentFile -Path $paths.Manifest
    if ($Environment -eq 'local') {
        if (-not $values['TORCHAT_COMPOSE_PROJECT']) { $values['TORCHAT_COMPOSE_PROJECT'] = 'torchat-local' }
        if (-not $values['TORCHAT_HTTP_PORT']) { $values['TORCHAT_HTTP_PORT'] = '8080' }
        if (-not $values['TORCHAT_SOCKS_PORT']) { $values['TORCHAT_SOCKS_PORT'] = '9050' }
    }

    if (Test-Path -LiteralPath $paths.RuntimeEnvironment) {
        foreach ($pair in (Read-TorChatEnvironmentFile -Path $paths.RuntimeEnvironment).GetEnumerator()) {
            if ($pair.Key -in @('TORCHAT_ONION_URL','TORCHAT_DATABASE_PASSWORD','TORCHAT_PAIRING_SECRET')) {
                $values[$pair.Key] = $pair.Value
            }
        }
    }

    if (-not $values['TORCHAT_DATABASE_PASSWORD']) { $values['TORCHAT_DATABASE_PASSWORD'] = New-TorChatSecret -Bytes 24 }
    if (-not $values['TORCHAT_PAIRING_SECRET']) { $values['TORCHAT_PAIRING_SECRET'] = New-TorChatSecret -Bytes 32 }
    if (-not $values['TORCHAT_TORKA_PAIRING_CODE']) { $values['TORCHAT_TORKA_PAIRING_CODE'] = '42424242' }
    $values['TORCHAT_ENVIRONMENT'] = $Environment

    $state = [pscustomobject]@{ Paths = $paths; Values = $values }
    Save-TorChatEnvironmentState -EnvironmentState $state
    return $state
}

function Import-TorChatEnvironmentState {
    param([Parameter(Mandatory = $true)]$EnvironmentState, [switch]$RequireOnion)
    foreach ($pair in $EnvironmentState.Values.GetEnumerator()) {
        Set-Item -Path "Env:$($pair.Key)" -Value ([string]$pair.Value)
    }
    if ($RequireOnion -and $EnvironmentState.Values['TORCHAT_ONION_URL'] -notmatch '^https?://[a-z2-7]{56}\.onion$') {
        throw "Environment '$($EnvironmentState.Values['TORCHAT_ENVIRONMENT'])' has no valid TORCHAT_ONION_URL. Start the stack or rotate the onion identity first."
    }
}

function Set-TorChatEnvironmentOnion {
    param(
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$OnionUrl
    )
    if ($OnionUrl -notmatch '^https?://[a-z2-7]{56}\.onion$') { throw "Invalid v3 onion URL: $OnionUrl" }
    $EnvironmentState.Values['TORCHAT_ONION_URL'] = $OnionUrl
    Save-TorChatEnvironmentState -EnvironmentState $EnvironmentState
    Set-Item -Path 'Env:TORCHAT_ONION_URL' -Value $OnionUrl
}

function Get-TorChatComposeContext {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$EnvironmentState
    )
    $composeFile = Join-Path $RepositoryRoot 'infra\docker\compose.dev.yml'
    [pscustomobject]@{
        File = $composeFile
        Project = [string]$EnvironmentState.Values['TORCHAT_COMPOSE_PROJECT']
        Arguments = @(
            'compose',
            '--project-name', [string]$EnvironmentState.Values['TORCHAT_COMPOSE_PROJECT'],
            '--env-file', $EnvironmentState.Paths.RuntimeEnvironment,
            '-f', $composeFile
        )
    }
}

function Get-TorChatDefaults {
    [pscustomobject]@{
        Environment = 'local'
        Configuration = 'debug'
        UiMode = 'dashboard'
        Verbosity = 'normal'
        BuildPolicy = 'smart'
        OnionPolicy = 'preserve'
        DatabasePolicy = 'preserve'
        ClientDataPolicy = 'preserve'
        StackPolicy = 'ensure'
        InstallPolicy = 'if-changed'
        RunPolicy = 'restart'
        Readiness = 'development'
    }
}

Export-ModuleMember -Function @(
    'Read-TorChatEnvironmentFile',
    'Get-TorChatEnvironmentPaths',
    'Get-TorChatEnvironmentState',
    'Import-TorChatEnvironmentState',
    'Set-TorChatEnvironmentOnion',
    'Save-TorChatEnvironmentState',
    'Get-TorChatComposeContext',
    'Get-TorChatDefaults'
)
