param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path) {
    $full = Join-Path $RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "required conversation focus file is missing: $Path"
    }
    return Get-Content -Raw -LiteralPath $full
}

$feature = Require-Text 'packages/torchat-runtime/src/features/conversations/mod.rs'
foreach ($required in @(
    'pub trait ClientRuntimeConversationFacade',
    'feature_set_conversation_focus',
    'conversation_by_id',
    'conversation_is_attended',
    'mark_conversation_read',
    'ConversationReadChanged'
)) {
    if (-not $feature.Contains($required)) {
        throw "conversation focus feature boundary is incomplete: $required"
    }
}
if ($feature.Contains('conversations()?.into_iter()')) {
    throw 'conversation focus feature performs a forbidden collection scan'
}

$handler = Require-Text 'packages/torchat-client-engine/src/actor/commands/conversations/set_conversation_focus.rs'
foreach ($required in @(
    'ClientRuntimeConversationFacade',
    'feature_set_conversation_focus',
    'queue_peer_conversation_focus'
)) {
    if (-not $handler.Contains($required)) {
        throw "conversation focus handler bypasses its feature boundary: $required"
    }
}
if ($handler.Contains('runtime.set_conversation_focus')) {
    throw 'conversation focus handler still calls the ClientRuntime monolith'
}

Write-Host '[torca] conversation focus feature check passed'
