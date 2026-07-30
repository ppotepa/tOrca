Set-StrictMode -Version Latest

function Test-TorChatInteractiveHost {
    param([Parameter(Mandatory = $true)]$Context)
    if ($Context.UiMode -ne 'dashboard') { return $false }
    if ($env:CI -or [Console]::IsOutputRedirected) { return $false }
    return $true
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
    Write-Host ("│ UI            {0,-49} │" -f $Context.UiMode)
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
    Write-Host ("  ●  {0}" -f $Name) -ForegroundColor Cyan
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
    } elseif ($Context.Verbosity -in @('detailed', 'trace')) {
        Write-Host ("     {0,3}%  {1} {2}" -f $Percent, $Name, $Detail) -ForegroundColor DarkCyan
    }
}

function Write-TorChatStageResult {
    param([Parameter(Mandatory = $true)]$Result)

    $seconds = [Math]::Round(([double]$Result.DurationMs / 1000), 1)
    $duration = if ($seconds -gt 0) { " · ${seconds}s" } else { '' }
    switch ($Result.State) {
        'Ready'   { Write-Host ("  ✓  {0}{1}" -f $Result.Name, $duration) -ForegroundColor Green }
        'Skipped' { Write-Host ("  ◌  {0} · skipped" -f $Result.Name) -ForegroundColor DarkGray }
        'Warning' { Write-Host ("  !  {0}{1} · {2}" -f $Result.Name, $duration, $Result.Message) -ForegroundColor Yellow }
        'Failed'  { Write-Host ("  x  {0}{1} · {2}" -f $Result.Name, $duration, $Result.Message) -ForegroundColor Red }
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
    'Write-TorChatBanner',
    'Write-TorChatInfo',
    'Write-TorChatWarning',
    'Write-TorChatFailure',
    'Write-TorChatStageStart',
    'Write-TorChatStageProgress',
    'Write-TorChatStageResult',
    'Write-TorChatSummary'
)
