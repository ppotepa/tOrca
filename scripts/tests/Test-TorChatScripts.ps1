[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Include '*.ps1','*.psm1' | Sort-Object FullName)
$failures = New-Object System.Collections.ArrayList

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -eq 0) {
        Write-Host ("[PASS] {0}" -f $file.FullName.Substring($scriptsRoot.Length + 1)) -ForegroundColor Green
        continue
    }
    foreach ($error in $errors) {
        $record = [pscustomobject]@{
            File = $file.FullName
            Line = $error.Extent.StartLineNumber
            Column = $error.Extent.StartColumnNumber
            Message = $error.Message
        }
        [void]$failures.Add($record)
        Write-Host ("[FAIL] {0}:{1}:{2} {3}" -f $file.FullName, $record.Line, $record.Column, $record.Message) -ForegroundColor Red
    }
}

if ($failures.Count -gt 0) {
    throw "PowerShell syntax validation failed with $($failures.Count) parser error(s)."
}

Write-Host "Validated $($files.Count) PowerShell files." -ForegroundColor Cyan
