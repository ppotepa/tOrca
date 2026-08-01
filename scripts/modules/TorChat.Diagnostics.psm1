Set-StrictMode -Version Latest

function Invoke-TorChatDiagnosticCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    try {
        $output = @(& $Action 2>&1)
        ($output | Out-String).TrimEnd() | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        $_.Exception.ToString() | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

function Collect-TorChatDiagnostics {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [string]$Device
    )
    $root = Join-Path $Context.RunDirectory 'diagnostics'
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
        $dockerReady = $false
        try {
            [void](Assert-TorChatDockerEngine -Context $Context)
            $dockerReady = $true
        } catch {
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $root 'docker-unavailable.txt') -Encoding UTF8
        }
        if ($dockerReady) {
            Invoke-TorChatDiagnosticCapture -Path (Join-Path $root 'docker-ps.txt') -Action { docker @($compose.Arguments + @('ps','-a')) }
            foreach ($service in @('postgres','server','tor','torka')) {
                Invoke-TorChatDiagnosticCapture -Path (Join-Path $root "docker-$service.log") -Action { docker @($compose.Arguments + @('logs','--timestamps','--no-color','--tail','2000',$service)) }
            }
            Invoke-TorChatDiagnosticCapture -Path (Join-Path $root 'docker-info.txt') -Action { docker info }
        }
    } else {
        'docker executable is not installed or is not on PATH.' | Set-Content -LiteralPath (Join-Path $root 'docker-unavailable.txt') -Encoding UTF8
    }

    if ($env:OS -eq 'Windows_NT') {
        $desktopDiagnostics = Join-Path $root 'desktop'
        New-Item -ItemType Directory -Force -Path $desktopDiagnostics | Out-Null
        Invoke-TorChatDiagnosticCapture -Path (Join-Path $root 'windows-processes.txt') -Action {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('torchat_mobile.exe','torchat-desktop.exe','tor.exe','adb.exe') } |
                Select-Object Name,ProcessId,ParentProcessId,ExecutablePath,CommandLine |
                Format-List
        }
        $desktopRoot = Join-Path $Context.RepositoryRoot '.torchat\clients\desktop\engine-logs'
        $latestDesktopJournal = Get-ChildItem -LiteralPath $desktopRoot -Filter 'startup-*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($latestDesktopJournal) {
            Copy-Item -LiteralPath $latestDesktopJournal.FullName -Destination (Join-Path $desktopDiagnostics 'startup-journal.jsonl') -Force
        }
        $desktopLog = Get-ChildItem -LiteralPath (Join-Path $Context.RepositoryRoot '.torchat\logs') -Recurse -Filter 'desktop.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($desktopLog) {
            Copy-Item -LiteralPath $desktopLog.FullName -Destination (Join-Path $desktopDiagnostics 'runtime-stdio.log') -Force
        }
        $torrc = Join-Path $Context.RepositoryRoot '.torchat\clients\desktop\tor\data\torrc.generated'
        if (Test-Path -LiteralPath $torrc) {
            Copy-Item -LiteralPath $torrc -Destination (Join-Path $desktopDiagnostics 'torrc.generated') -Force
        }
    }

    if (Get-Command adb -ErrorAction SilentlyContinue) {
        $resolved = $null
        try { $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device -DiscoveryTimeoutSeconds 3 } catch { }
        if ($resolved) {
            $androidRoot = Save-TorChatAndroidDiagnostics -Context $Context -Device $resolved
            Copy-Item -LiteralPath $androidRoot -Destination (Join-Path $root 'android') -Recurse -Force
            Invoke-TorChatDiagnosticCapture -Path (Join-Path $root 'android-device.txt') -Action {
                adb -s $resolved shell getprop ro.product.manufacturer
                adb -s $resolved shell getprop ro.product.model
                adb -s $resolved shell getprop ro.build.version.release
                adb -s $resolved shell pidof org.torchat.mobile
            }
        }
    }

    [pscustomobject]@{ State = 'Ready'; Code = 'DIAGNOSTICS_COLLECTED'; Message = "Diagnostics collected in $root"; Path = $root }
}

function Test-TorChatSensitiveDiagnosticFile {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $name = $File.Name.ToLowerInvariant()
    if ($name -in @('.env','hostname','private_key','secret_key')) { return $true }
    if ($name -match '(^|[._-])(secret|secrets|private|identity|keystore|keyring)([._-]|$)') { return $true }
    if ($name -match 'hs_ed25519_(secret_key|public_key)') { return $true }
    return $File.Extension.ToLowerInvariant() -in @(
        '.db', '.sqlite', '.sqlite3', '.key', '.pem', '.p12', '.pfx',
        '.jks', '.keystore', '.der', '.bin', '.apk', '.exe', '.dll'
    )
}

function Protect-TorChatDiagnosticText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return '' }
    $protected = $Text

    # Explicit structured fields are redacted before generic token patterns so
    # surrounding JSON/log syntax stays useful for debugging.
    $protected = [regex]::Replace(
        $protected,
        '(?i)("(?:body|text|messageBody|offerPayload|payload|imageBase64|attachmentData|ciphertext|databaseKey|identityPrivateKey|sessionToken|capability|proof)"\s*:\s*")((?:\\.|[^"\\])*)(")',
        '$1<redacted>$3'
    )
    $protected = [regex]::Replace(
        $protected,
        '(?im)^\s*(TORCHAT_(?:DATABASE_KEY|IDENTITY_PRIVATE_KEY|PAIRING_SECRET|SESSION_TOKEN|CAPABILITY|PROOF)|DATABASE_URL|POSTGRES_PASSWORD)\s*=\s*.*$',
        '$1=<redacted>'
    )
    $protected = [regex]::Replace(
        $protected,
        '(?i)(authorization\s*[:=]\s*bearer\s+)[A-Za-z0-9._~+/=-]+',
        '$1<redacted>'
    )
    $protected = [regex]::Replace(
        $protected,
        '(?i)(session[_-]?token|database[_-]?key|identity[_-]?private[_-]?key|pairing[_-]?secret|private[_-]?key|capability|proof)(\s*[:=]\s*)[^\s,;]+',
        '$1$2<redacted>'
    )
    $protected = [regex]::Replace(
        $protected,
        '(?i)\b[a-z2-7]{56}\.onion\b',
        '<redacted-onion>'
    )
    $protected = [regex]::Replace(
        $protected,
        '-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----',
        '<redacted-key-material>'
    )
    # Image/message payloads are frequently emitted as long base64 or hex
    # strings. Preserve short identifiers and hashes, redact only large blobs.
    $protected = [regex]::Replace(
        $protected,
        '(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{160,}={0,2}(?![A-Za-z0-9+/=])',
        '<redacted-binary-payload>'
    )
    $protected = [regex]::Replace(
        $protected,
        '(?i)(?<![0-9a-f])[0-9a-f]{512,}(?![0-9a-f])',
        '<redacted-binary-payload>'
    )

    return $protected
}

function Copy-TorChatSanitizedDiagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
    $copied = 0
    $excluded = 0
    $unreadable = 0

    foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse -Force) {
        $relative = [System.IO.Path]::GetRelativePath($SourceDirectory, $file.FullName)
        if (Test-TorChatSensitiveDiagnosticFile -File $file) {
            $excluded += 1
            continue
        }

        $destination = Join-Path $DestinationDirectory $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            Protect-TorChatDiagnosticText -Text $text |
                Set-Content -LiteralPath $destination -Encoding UTF8
            $copied += 1
        } catch {
            $unreadable += 1
        }
    }

    [pscustomobject]@{
        Copied = $copied
        Excluded = $excluded
        Unreadable = $unreadable
    }
}

function Export-TorChatDiagnostics {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [string]$Destination
    )
    if (-not (Test-Path -LiteralPath $SourceDirectory)) { throw "Diagnostics directory does not exist: $SourceDirectory" }
    if (-not $Destination) { $Destination = Join-Path $Context.RepositoryRoot ".torchat\exports\torchat-$($Context.RunId).zip" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }

    $staging = Join-Path $Context.RunDirectory 'sanitized-diagnostics'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    try {
        $summary = Copy-TorChatSanitizedDiagnostics -SourceDirectory $SourceDirectory -DestinationDirectory $staging
        @{
            schema = 1
            sanitized = $true
            copiedFiles = $summary.Copied
            excludedSensitiveFiles = $summary.Excluded
            unreadableFiles = $summary.Unreadable
            createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staging 'sanitization-manifest.json') -Encoding UTF8
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $Destination -CompressionLevel Optimal
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    [pscustomobject]@{ State = 'Ready'; Code = 'DIAGNOSTICS_EXPORTED'; Message = $Destination; Path = $Destination }
}

function Get-TorChatRecentRuns {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot, [int]$Limit = 10)
    $root = Join-Path $RepositoryRoot '.torchat\runs'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $Limit | ForEach-Object {
        $summaryPath = Join-Path $_.FullName 'summary.json'
        if (Test-Path -LiteralPath $summaryPath) {
            try { Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json } catch { [pscustomobject]@{ runId = $_.Name; state = 'Unknown' } }
        } else { [pscustomobject]@{ runId = $_.Name; state = 'RunningOrInterrupted' } }
    })
}

Export-ModuleMember -Function @(
    'Collect-TorChatDiagnostics',
    'Export-TorChatDiagnostics',
    'Get-TorChatRecentRuns',
    'Protect-TorChatDiagnosticText'
)
