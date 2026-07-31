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
        Invoke-TorChatDiagnosticCapture -Path (Join-Path $root 'windows-processes.txt') -Action {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('torchat_mobile.exe','torchat-desktop.exe','tor.exe','adb.exe') } |
                Select-Object Name,ProcessId,ParentProcessId,ExecutablePath,CommandLine |
                Format-List
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
    Compress-Archive -Path (Join-Path $SourceDirectory '*') -DestinationPath $Destination -CompressionLevel Optimal
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

Export-ModuleMember -Function @('Collect-TorChatDiagnostics','Export-TorChatDiagnostics','Get-TorChatRecentRuns')
