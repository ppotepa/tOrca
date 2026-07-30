Set-StrictMode -Version Latest

function Test-TorChatInteractiveHost {
    param([Parameter(Mandatory = $true)]$Context)
    if ($Context.UiMode -ne 'dashboard') { return $false }
    if ($env:CI -or [Console]::IsOutputRedirected) { return $false }
    return $true
}

function Initialize-TorChatConsole {
    param([Parameter(Mandatory = $true)]$Context)

    # JSON is intended for automation. Every human-facing invocation begins
    # with a fresh dashboard, while redirected output remains untouched.
    if ($Context.UiMode -eq 'json' -or $env:CI -or [Console]::IsOutputRedirected) { return }
    try { Clear-Host } catch { }
}

function Get-TorChatStageOrdinal {
    param([Parameter(Mandatory = $true)]$Context)
    return (@($Context.Results).Count + 1)
}

function Write-TorChatBanner {
    param([Parameter(Mandatory = $true)]$Context)

    $width = 66
    $line = '─' * ($width - 2)
    Write-Host "╭$line╮" -ForegroundColor DarkCyan
    Write-Host ("│ TorChat · {0,-54} │" -f "$($Context.Command) $($Context.Target)") -ForegroundColor Cyan
    Write-Host ("│ Run           {0,-49} │" -f $Context.RunId.Substring(0, [Math]::Min(12, $Context.RunId.Length)))
    Write-Host ("│ Environment   {0,-49} │" -f $Context.Environment)
    Write-Host ("│ Configuration {0,-49} │" -f $Context.Configuration)
    Write-Host ("│ Display       {0,-49} │" -f "$($Context.UiMode) / $($Context.Verbosity)")
    Write-Host ("│ Full logs     {0,-49} │" -f ".torchat\runs\$($Context.RunId)\logs")
    Write-Host "╰$line╯" -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-TorChatInfo {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "  i  $Message" -ForegroundColor Cyan
}

function Write-TorChatWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "  !  $Message" -ForegroundColor Yellow
}

function Write-TorChatFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "  x  $Message" -ForegroundColor Red
}

function Write-TorChatStageStart {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (Test-TorChatInteractiveHost -Context $Context) {
        Write-Progress -Id 4101 -Activity "TorChat · $($Context.Command) $($Context.Target)" -Status $Name -PercentComplete -1
    }
    $ordinal = Get-TorChatStageOrdinal -Context $Context
    Write-Host ("  [{0,2}] ●  Running  {1}" -f $ordinal, $Name) -ForegroundColor Cyan
    if ($Context.Verbosity -in @('normal','detailed','trace')) {
        Write-Host '       active; output is being written to the run log' -ForegroundColor DarkGray
    }
}

function Write-TorChatStageProgress {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$Percent,
        [string]$Detail = ''
    )
    if (Test-TorChatInteractiveHost -Context $Context) {
        $status = if ($Detail) { "$Name · $Detail" } else { $Name }
        Write-Progress -Id 4101 -Activity "TorChat · $($Context.Command) $($Context.Target)" -Status $status -PercentComplete $Percent
    }
    if ($Context.Verbosity -in @('normal', 'detailed', 'trace')) {
        $lastKey = "progress:$Name"
        $lastPercent = if ($Context.Metadata.ContainsKey($lastKey)) { [int]$Context.Metadata[$lastKey] } else { -10 }
        if ($Percent -ge 100 -or ($Percent - $lastPercent) -ge 10) {
            $Context.Metadata[$lastKey] = $Percent
            $suffix = if ($Detail) { " - $Detail" } else { '' }
            Write-Host ("       {0,3}%  {1}{2}" -f $Percent, $Name, $suffix) -ForegroundColor DarkCyan
        }
    }
}

function Write-TorChatStageResult {
    param([Parameter(Mandatory = $true)]$Result)

    $seconds = [Math]::Round(([double]$Result.DurationMs / 1000), 1)
    $duration = if ($seconds -gt 0) { " · ${seconds}s" } else { '' }
    switch ($Result.State) {
        'Ready'   { Write-Host ("  ✓  Ready    {0}{1}" -f $Result.Name, $duration) -ForegroundColor Green }
        'Skipped' { Write-Host ("  ◌  Skipped  {0} · {1}" -f $Result.Name, $Result.Message) -ForegroundColor DarkGray }
        'Warning' { Write-Host ("  !  Warning  {0}{1} · {2}" -f $Result.Name, $duration, $Result.Message) -ForegroundColor Yellow }
        'Failed'  { Write-Host ("  x  Failed   {0}{1} · {2}" -f $Result.Name, $duration, $Result.Message) -ForegroundColor Red }
        default   { Write-Host ("  •  {0}{1}" -f $Result.Name, $duration) }
    }
}

function Write-TorChatSummary {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$State
    )

    if (Test-TorChatInteractiveHost -Context $Context) {
        Write-Progress -Id 4101 -Activity "TorChat · $($Context.Command) $($Context.Target)" -Completed
    }

    $elapsed = [Math]::Round(((Get-Date) - $Context.StartedAt).TotalSeconds, 1)
    $ready = @($Context.Results | Where-Object State -eq 'Ready').Count
    $warnings = @($Context.Results | Where-Object State -eq 'Warning').Count
    $failed = @($Context.Results | Where-Object State -eq 'Failed').Count
    $skipped = @($Context.Results | Where-Object State -eq 'Skipped').Count

    Write-Host ''
    $color = switch ($State) {
        'Succeeded' { 'Green' }
        'SucceededWithWarnings' { 'Yellow' }
        default { 'Red' }
    }
    Write-Host ("╭─ {0} " -f $State) -ForegroundColor $color
    Write-Host ("│ ready={0} warnings={1} failed={2} skipped={3} elapsed={4}s" -f $ready, $warnings, $failed, $skipped, $elapsed)
    Write-Host ("│ logs: {0}" -f $Context.RunDirectory)
    Write-Host '╰────────────────────────────────────────────────────────────' -ForegroundColor $color
}

Export-ModuleMember -Function @(
    'Test-TorChatInteractiveHost',
    'Initialize-TorChatConsole',
    'Write-TorChatBanner',
    'Write-TorChatInfo',
    'Write-TorChatWarning',
    'Write-TorChatFailure',
    'Write-TorChatStageStart',
    'Write-TorChatStageProgress',
    'Write-TorChatStageResult',
    'Write-TorChatSummary'
)
