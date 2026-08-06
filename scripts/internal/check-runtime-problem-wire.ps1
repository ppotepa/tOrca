param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path) {
    $full = Join-Path $RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "required runtime problem wire file is missing: $Path"
    }
    return Get-Content -Raw -LiteralPath $full
}

$eventContract = Require-Text 'packages/torchat-client-engine/src/event.rs'
foreach ($required in @(
    'problem: RuntimeProblem',
    'pub fn error(',
    'RuntimeErrorCategory',
    'diagnostic_context: Some(message)'
)) {
    if (-not $eventContract.Contains($required)) {
        throw "engine response contract is missing structured runtime problem support: $required"
    }
}

$processor = Require-Text 'packages/torchat-client-engine/src/actor/command_pipeline/processor.rs'
if ($processor.Contains('ResponseResult::Error {')) {
    throw 'command processor constructs legacy text-only error responses'
}
if (-not $processor.Contains('ResponseResult::error(')) {
    throw 'command processor does not use the structured error constructor'
}

$responseRegistry = Require-Text 'packages/torchat-client-engine/src/output/response_registry.rs'
if (-not $responseRegistry.Contains('ResponseResult::error(code, message)')) {
    throw 'pending response registry does not emit structured shutdown problems'
}

$androidProblem = Require-Text 'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/EngineProblemException.kt'
foreach ($required in @('EngineProblemException', 'problem: Map<String, Any?>', 'toEngineProblemMap')) {
    if (-not $androidProblem.Contains($required)) {
        throw "Android structured problem bridge is incomplete: $required"
    }
}

$androidHost = Require-Text 'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/AndroidEngineHost.kt'
foreach ($required in @('optJSONObject("problem")', 'EngineProblemException(problem, message)')) {
    if (-not $androidHost.Contains($required)) {
        throw "Android engine host drops the structured runtime problem: $required"
    }
}

$androidDispatcher = Require-Text 'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/EngineMethodDispatcher.kt'
foreach ($required in @('catch (problem: EngineProblemException)', 'result.error(code, problem.message, problem.problem)')) {
    if (-not $androidDispatcher.Contains($required)) {
        throw "MethodChannel boundary does not publish RuntimeProblem details: $required"
    }
}

$flutterResponse = Require-Text 'apps/mobile/flutter/lib/core/runtime/runtime_response.dart'
foreach ($required in @('RuntimeProblem? problem', "result['problem']", 'RuntimeProblem.fromJson')) {
    if (-not $flutterResponse.Contains($required)) {
        throw "Flutter response model does not preserve RuntimeProblem: $required"
    }
}

$flutterProblemAdapter = Require-Text 'apps/mobile/flutter/lib/core/problems/runtime_problem_from_error.dart'
if (-not $flutterProblemAdapter.Contains('details is Map')) {
    throw 'Flutter PlatformException adapter does not decode structured problem details'
}

Write-Host '[torca] runtime problem wire check passed'
