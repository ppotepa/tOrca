function Import-TorChatDevConfig {
    param([string]$RepoRoot, [switch]$AllowPlaceholder)
    $path = Join-Path $RepoRoot "infra\config\dev.env"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing canonical development config: $path"
    }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { continue }
        $name = $Matches[1]
        $value = $Matches[2].Trim().Trim('"').Trim("'")
        Set-Item -Path "Env:$name" -Value $value
    }
    if ($env:TORCHAT_ONION_URL -match 'CHANGE-ME' -and -not $AllowPlaceholder) {
        throw "Set TORCHAT_ONION_URL in $path to the real development v3 onion URL."
    }
    if ($env:TORCHAT_ONION_URL -match 'CHANGE-ME' -and $AllowPlaceholder) { return }
    if ($env:TORCHAT_ONION_URL -notmatch '^https?://[a-z2-7]{56}\.onion$') {
        throw "TORCHAT_ONION_URL in $path must be an exact v3 onion URL."
    }
}

function Set-TorChatDevOnionUrl {
    param([string]$RepoRoot, [string]$Url)
    $path = Join-Path $RepoRoot "infra\config\dev.env"
    $lines = @(Get-Content -LiteralPath $path | Where-Object { $_ -notmatch '^\s*TORCHAT_ONION_URL\s*=' })
    $lines = @("TORCHAT_ONION_URL=$Url") + $lines
    # Windows PowerShell's `-Encoding utf8` writes a BOM. Gradle reads the
    # first key literally, so a BOM would make TORCHAT_ONION_URL disappear.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($path, [string[]]$lines, $utf8NoBom)
    $env:TORCHAT_ONION_URL = $Url
}
