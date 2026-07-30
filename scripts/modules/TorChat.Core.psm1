Set-StrictMode -Version Latest

function New-TorChatRunContext {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][ValidateSet('local','staging','production')][string]$Environment,
        [Parameter(Mandatory = $true)][ValidateSet('debug','release')][string]$Configuration,
        [ValidateSet('dashboard','plain','json')][string]$UiMode = 'dashboard',
        [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal',
        [switch]$NoColor,
        [switch]$DryRun
    )

    $runId = [Guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $RepositoryRoot ".torchat\runs\$runId"
    $logDirectory = Join-Path $runDirectory 'logs'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

    $context = [pscustomobject]@{
        RunId = $runId
        RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        ScriptsRoot = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'scripts'
        Command = $Command
        Target = $Target
        Environment = $Environment
        Configuration = $Configuration
        UiMode = $UiMode
        Verbosity = $Verbosity
        NoColor = [bool]$NoColor
        DryRun = [bool]$DryRun
        StartedAt = Get-Date
        RunDirectory = $runDirectory
        LogDirectory = $logDirectory
        EventsPath = Join-Path $runDirectory 'events.jsonl'
        SummaryPath = Join-Path $runDirectory 'summary.json'
        Results = [System.Collections.ArrayList]::new()
        Metadata = @{}
    }

    $env:TORCHAT_DEPLOY_RUN_ID = $runId
    [pscustomobject]@{
        runId = $runId
        command = $Command
        target = $Target
        environment = $Environment
        configuration = $Configuration
        ui = $UiMode
        verbosity = $Verbosity
        dryRun = [bool]$DryRun
        startedAt = $context.StartedAt.ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDirectory 'run.json') -Encoding UTF8

    return $context
}

function Write-TorChatEvent {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$State,
        [string]$Message = '',
        [int]$Progress = -1,
        [hashtable]$Data = @{}
    )

    $event = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        runId = $Context.RunId
        command = $Context.Command
        target = $Context.Target
        stage = $Stage
        state = $State
        message = $Message
    }
    if ($Progress -ge 0) { $event.progress = $Progress }
    if ($Data.Count -gt 0) { $event.data = $Data }
    ($event | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $Context.EventsPath -Encoding UTF8

    if ($Context.UiMode -eq 'json') {
        Write-Output ($event | ConvertTo-Json -Depth 8 -Compress)
    }
}

function New-TorChatStageResult {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Ready','Skipped','Warning','Failed')][string]$State,
        [string]$Code = '',
        [string]$Message = '',
        [long]$DurationMs = 0,
        $Data = $null
    )
    [pscustomobject]@{
        Id = $Id
        Name = $Name
        State = $State
        Code = $Code
        Message = $Message
        DurationMs = $DurationMs
        Data = $Data
    }
}

function Invoke-TorChatStage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [bool]$Required = $true,
        [switch]$Skip
    )

    if ($Skip -or $Context.DryRun) {
        $reason = if ($Context.DryRun) { 'dry run' } else { 'not required by plan' }
        $result = New-TorChatStageResult -Id $Id -Name $Name -State Skipped -Code 'STAGE_SKIPPED' -Message $reason
        [void]$Context.Results.Add($result)
        Write-TorChatEvent -Context $Context -Stage $Id -State 'skipped' -Message $reason
        Write-TorChatStageResult -Result $result
        return $result
    }

    Write-TorChatEvent -Context $Context -Stage $Id -State 'running'
    Write-TorChatStageStart -Context $Context -Id $Id -Name $Name
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $data = & $Action
        $stopwatch.Stop()
        $state = 'Ready'
        $code = 'STAGE_READY'
        $message = ''
        if ($null -ne $data -and $data.PSObject.Properties.Name -contains 'State') {
            if ($data.State -in @('Ready','Skipped','Warning','Failed')) { $state = [string]$data.State }
            if ($data.PSObject.Properties.Name -contains 'Code') { $code = [string]$data.Code }
            if ($data.PSObject.Properties.Name -contains 'Message') { $message = [string]$data.Message }
        }
        $result = New-TorChatStageResult -Id $Id -Name $Name -State $state -Code $code -Message $message -DurationMs $stopwatch.ElapsedMilliseconds -Data $data
        [void]$Context.Results.Add($result)
        Write-TorChatEvent -Context $Context -Stage $Id -State $state.ToLowerInvariant() -Message $message -Data @{ durationMs = $stopwatch.ElapsedMilliseconds; code = $code }
        Write-TorChatStageResult -Result $result
        if ($state -eq 'Failed' -and $Required) { throw ($message | ForEach-Object { if ($_){$_}else{"Required stage '$Name' failed."} }) }
        return $result
    } catch {
        $stopwatch.Stop()
        $message = $_.Exception.Message
        $state = if ($Required) { 'Failed' } else { 'Warning' }
        $code = if ($Required) { 'STAGE_FAILED' } else { 'OPTIONAL_STAGE_FAILED' }
        $result = New-TorChatStageResult -Id $Id -Name $Name -State $state -Code $code -Message $message -DurationMs $stopwatch.ElapsedMilliseconds
        [void]$Context.Results.Add($result)
        Write-TorChatEvent -Context $Context -Stage $Id -State $state.ToLowerInvariant() -Message $message -Data @{ durationMs = $stopwatch.ElapsedMilliseconds; code = $code }
        Write-TorChatStageResult -Result $result
        if ($Required) { throw }
        return $result
    }
}

function Invoke-TorChatNative {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$LogName,
        [int[]]$AllowedExitCodes = @(0)
    )

    $logPath = Join-Path $Context.LogDirectory $LogName
    $previousLocation = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        $output = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).TrimEnd()
        if ($text) { Add-Content -LiteralPath $logPath -Value $text -Encoding UTF8 }
        if ($Context.Verbosity -in @('detailed','trace') -and $text) {
            $output | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        }
        if ($AllowedExitCodes -notcontains $exitCode) {
            $tail = @($output | Select-Object -Last 12) -join [Environment]::NewLine
            throw "$FilePath failed with exit code $exitCode. Log: $logPath$([Environment]::NewLine)$tail"
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; LogPath = $logPath }
    } finally {
        Set-Location -LiteralPath $previousLocation
    }
}

function Assert-TorChatTool {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required tool: $Name"
    }
}

function Complete-TorChatRun {
    param([Parameter(Mandatory = $true)]$Context)

    $failed = @($Context.Results | Where-Object State -eq 'Failed').Count
    $warnings = @($Context.Results | Where-Object State -eq 'Warning').Count
    $state = if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'SucceededWithWarnings' } else { 'Succeeded' }
    $summary = [ordered]@{
        runId = $Context.RunId
        command = $Context.Command
        target = $Context.Target
        environment = $Context.Environment
        configuration = $Context.Configuration
        state = $state
        startedAt = $Context.StartedAt.ToUniversalTime().ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        results = @($Context.Results)
    }
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Context.SummaryPath -Encoding UTF8
    Write-TorChatEvent -Context $Context -Stage 'run' -State $state.ToLowerInvariant()
    Write-TorChatSummary -Context $Context -State $state
    return $state
}

Export-ModuleMember -Function @(
    'New-TorChatRunContext',
    'Write-TorChatEvent',
    'New-TorChatStageResult',
    'Invoke-TorChatStage',
    'Invoke-TorChatNative',
    'Assert-TorChatTool',
    'Complete-TorChatRun'
)
