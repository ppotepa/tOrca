[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    throw 'OpenSSL is required for the Torca update-manifest tooling test.'
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("torca-update-test-" + [guid]::NewGuid().ToString('N'))
$artifactRoot = Join-Path $tempRoot 'artifacts'
$privateKey = Join-Path $tempRoot 'private.pem'
$publicDer = Join-Path $tempRoot 'public.der'
$manifest = Join-Path $artifactRoot 'torca-update-manifest.json'
$receipt = Join-Path $tempRoot 'receipt.json'

try {
    New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
    [IO.File]::WriteAllBytes(
        (Join-Path $artifactRoot 'torca-test-android.apk'),
        [byte[]](0..255)
    )
    & openssl genpkey -algorithm ED25519 -out $privateKey
    if ($LASTEXITCODE -ne 0) { throw 'Unable to generate the test Ed25519 key.' }
    & openssl pkey -in $privateKey -pubout -outform DER -out $publicDer
    if ($LASTEXITCODE -ne 0) { throw 'Unable to derive the test Ed25519 public key.' }
    $der = [IO.File]::ReadAllBytes($publicDer)
    $publicKey = [Convert]::ToBase64String($der[($der.Length - 32)..($der.Length - 1)])

    & (Join-Path $repositoryRoot 'scripts/release/generate-update-manifest.ps1') `
        -RepositoryRoot $repositoryRoot `
        -ArtifactDirectory $artifactRoot `
        -ArtifactBaseUrl 'https://example.invalid/torca' `
        -SigningPrivateKey $privateKey `
        -SigningKeyId 'torca-tooling-test' `
        -OutputPath $manifest
    & (Join-Path $repositoryRoot 'scripts/release/check-update-manifest.ps1') `
        -RepositoryRoot $repositoryRoot `
        -ManifestPath $manifest `
        -ArtifactDirectory $artifactRoot `
        -SigningPrivateKey $privateKey `
        -ExpectedKeyId 'torca-tooling-test' `
        -ExpectedPublicKey $publicKey `
        -ReceiptPath $receipt
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) {
        throw 'Update manifest checker did not create a receipt.'
    }

    Add-Content -LiteralPath (Join-Path $artifactRoot 'torca-test-android.apk') -Value 'tampered'
    $failedAsExpected = $false
    try {
        & (Join-Path $repositoryRoot 'scripts/release/check-update-manifest.ps1') `
            -RepositoryRoot $repositoryRoot `
            -ManifestPath $manifest `
            -ArtifactDirectory $artifactRoot `
            -SigningPrivateKey $privateKey `
            -ExpectedKeyId 'torca-tooling-test' `
            -ExpectedPublicKey $publicKey `
            -ReceiptPath $receipt
    } catch {
        $failedAsExpected = $_.Exception.Message -match 'size mismatch|SHA-256 mismatch'
    }
    if (-not $failedAsExpected) {
        throw 'Update manifest checker accepted a modified artifact.'
    }
    Write-Output 'Torca update-manifest signing and tamper tests passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
