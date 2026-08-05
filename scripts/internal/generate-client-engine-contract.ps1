param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$contractPath = Join-Path $RepositoryRoot 'common/client-engine-contract.json'
$contract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json -Depth 100
if ($null -eq $contract.commands -or $contract.commands.Count -eq 0) {
    throw 'client-engine-contract.json must define a non-empty commands array'
}

$publicMethods = @($contract.commands | ForEach-Object { [string]$_.publicMethod })
$wireNames = @($contract.commands | ForEach-Object { [string]$_.wireName })

if (($publicMethods | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'every command must define publicMethod'
}
if (($wireNames | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'every command must define wireName'
}
if (($publicMethods | Sort-Object -Unique).Count -ne $publicMethods.Count) {
    throw 'command publicMethod values must be unique'
}
if (($wireNames | Sort-Object -Unique).Count -ne $wireNames.Count) {
    throw 'command wireName values must be unique'
}

foreach ($command in $contract.commands) {
    if ($command.category -eq 'mutation' -and $command.durable -and -not $command.requiresCommandId) {
        throw "durable command '$($command.wireName)' must require commandId"
    }
    if ([string]::IsNullOrWhiteSpace([string]$command.handlerKey)) {
        throw "command '$($command.wireName)' must define handlerKey"
    }
}

$contract.methods.public = $publicMethods
$contract.commandTypes = $wireNames
$rendered = ($contract | ConvertTo-Json -Depth 100) + [Environment]::NewLine

if ($Check) {
    $existing = Get-Content -Raw -LiteralPath $contractPath
    if ($existing -cne $rendered) {
        throw 'client-engine-contract.json generated projections are stale'
    }
    Write-Host '[torca] client engine contract is current'
    exit 0
}

Set-Content -LiteralPath $contractPath -Value $rendered -NoNewline -Encoding utf8
Write-Host '[torca] regenerated client engine contract projections'
