[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$SigningPrivateKey,
    [Parameter(Mandatory = $true)][string]$ExpectedKeyId,
    [Parameter(Mandatory = $true)][string]$ExpectedPublicKey,
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$ArtifactDirectory = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
$SigningPrivateKey = (Resolve-Path -LiteralPath $SigningPrivateKey).Path
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    throw 'OpenSSL is required to verify the Torca update manifest.'
}

$release = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'release/version.json') -Raw |
    ConvertFrom-Json
$commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw 'Unable to resolve the update-manifest commit.'
}
$envelope = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ([int]$envelope.schema -ne 1 -or $envelope.algorithm -ne 'ed25519') {
    throw 'Unsupported Torca update manifest envelope.'
}
if ($envelope.keyId -ne $ExpectedKeyId) {
    throw 'Torca update manifest key id does not match the release input.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("torca-update-check-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    $payloadPath = Join-Path $temporaryRoot 'payload.json'
    $signaturePath = Join-Path $temporaryRoot 'signature.bin'
    $publicPemPath = Join-Path $temporaryRoot 'public.pem'
    $publicDerPath = Join-Path $temporaryRoot 'public.der'
    [IO.File]::WriteAllBytes($payloadPath, [Convert]::FromBase64String($envelope.payload))
    [IO.File]::WriteAllBytes($signaturePath, [Convert]::FromBase64String($envelope.signature))

    & openssl pkey -in $SigningPrivateKey -pubout -out $publicPemPath
    if ($LASTEXITCODE -ne 0) { throw 'Unable to derive the update public key.' }
    & openssl pkey -in $SigningPrivateKey -pubout -outform DER -out $publicDerPath
    if ($LASTEXITCODE -ne 0) { throw 'Unable to derive the raw update public key.' }
    $der = [IO.File]::ReadAllBytes($publicDerPath)
    if ($der.Length -lt 32) { throw 'Derived Ed25519 public key is malformed.' }
    $rawPublicKey = $der[($der.Length - 32)..($der.Length - 1)]
    $derivedPublicKey = [Convert]::ToBase64String($rawPublicKey)
    if ($derivedPublicKey -ne $ExpectedPublicKey) {
        throw 'The update private key does not match the public key embedded in the clients.'
    }

    & openssl pkeyutl -verify -pubin -inkey $publicPemPath -rawin `
        -in $payloadPath -sigfile $signaturePath
    if ($LASTEXITCODE -ne 0) {
        throw 'Torca update manifest signature verification failed.'
    }

    $payload = Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json
    if ($payload.product -ne 'Torca' -or
        $payload.version -ne $release.version -or
        [int]$payload.build -ne [int]$release.build -or
        $payload.commit -ne $commit) {
        throw 'Torca update payload does not match the current release and commit.'
    }
    if (@($payload.artifacts).Count -eq 0) {
        throw 'Torca update payload contains no artifacts.'
    }

    foreach ($artifact in $payload.artifacts) {
        $fileName = [IO.Path]::GetFileName($artifact.fileName)
        if ($fileName -ne $artifact.fileName) {
            throw "Update artifact file name is not a basename: $($artifact.fileName)"
        }
        $path = Join-Path $ArtifactDirectory $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Update artifact is missing: $fileName"
        }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -ne [long]$artifact.bytes) {
            throw "Update artifact size mismatch: $fileName"
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $artifact.sha256.ToLowerInvariant()) {
            throw "Update artifact SHA-256 mismatch: $fileName"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
        $ReceiptPath = Join-Path (Split-Path -Parent $ManifestPath) 'update-manifest-receipt.json'
    }
    $receiptDirectory = Split-Path -Parent $ReceiptPath
    if ($receiptDirectory) {
        New-Item -ItemType Directory -Force -Path $receiptDirectory | Out-Null
    }
    $receipt = [ordered]@{
        schema = 1
        product = 'Torca'
        version = $release.version
        build = [int]$release.build
        commit = $commit
        keyId = $ExpectedKeyId
        manifestSha256 = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        artifacts = @($payload.artifacts).Count
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        passed = $true
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($ReceiptPath, ($receipt | ConvertTo-Json -Depth 6), $utf8)
    Write-Host "[torca] signed update manifest passed: $ReceiptPath"
} finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
