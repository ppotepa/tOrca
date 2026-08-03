# TorChat PowerShell CLI

Use `scripts/torchat.ps1` as the public entrypoint for development, deployment,
testing and diagnostics:

```powershell
.\scripts\torchat.ps1 <command> <target> [options]
```

Implementation details live in `scripts/modules`. Files under `internal`,
`release` and `tests` are called by the CLI or CI unless a task explicitly says
to run them directly.

## Commands

```text
status  [all|stack|android|windows]
stack   [start|stop|restart|status|reset|repair]
build   [server|desktop-runtime|android|windows|clients|all]
deploy  [android|windows|all]
deploy-clean
run     [android|windows|all]
stop    [android|windows|all]
test    [runtime|flutter|android|windows|all]
device  [list|pair|connect|status]
```

The CLI itself is authoritative. Display its current syntax with:

```powershell
.\scripts\torchat.ps1 help
```

## Common workflows

```powershell
# Environment status
.\scripts\torchat.ps1 status all

# Start or restart the local stack while preserving data and onion identity
.\scripts\torchat.ps1 stack start
.\scripts\torchat.ps1 stack restart -OnionPolicy preserve

# Deploy Android to an automatically selected target
.\scripts\torchat.ps1 deploy android -Device auto

# Deploy Android to every eligible target
.\scripts\torchat.ps1 deploy android -Device all

# Deploy Windows and Android
.\scripts\torchat.ps1 deploy all

# Rebuild deployment artifacts from a clean build policy
.\scripts\torchat.ps1 deploy-clean
```

## Android emulator

Start an emulator independently from application deployment:

```powershell
.\scripts\start-android-emulator.ps1
```

Then deploy TorChat explicitly to the serial printed by the emulator script,
for example `emulator-5554`:

```powershell
.\scripts\torchat.ps1 deploy android -Device emulator-5554
```

Alternatively, start the emulator and deploy the application in one invocation:

```powershell
.\scripts\start-android-emulator.ps1 -RunApp -SkipStack
```

Use `-Device auto`, `-Device all` or a concrete ADB identifier when needed.

## Policies

Important options accepted by `torchat.ps1` include:

```text
-Environment      local | staging | production
-Configuration    debug | release
-BuildPolicy      smart | rebuild | skip
-OnionPolicy      preserve | rotate
-DatabasePolicy   preserve | reset
-ClientDataPolicy preserve | reset | clean
-StackPolicy      ensure | skip
-InstallPolicy    if-changed | always | skip
-RunPolicy        restart | start | skip
-Readiness        development | onion | strict
-Ui               dashboard | plain | json
-Verbosity        quiet | normal | detailed | trace
```

Defaults preserve onion identity, databases and client data. Reset or rotation
operations require an explicit policy and confirmation where enforced by the
CLI.

## Build and native libraries

Android deployment builds the Rust client-engine shared library for the target
ABI before assembling and installing the APK. Emulator builds require an
`x86_64` or matching emulator ABI library; a phone-only ARM build is not enough.

Windows deployment prepares the desktop runtime and Flutter application through
the same CLI. Prefer `BuildPolicy=smart` for normal work and `rebuild` when
native artifacts or generated bindings changed.

## Diagnostics

Each invocation stores logs under `.torchat/runs/<run-id>/`. Failures point to a
run-specific `failure.txt` and command logs. Diagnostic exports must remain
sanitized and must not include plaintext private keys, capability secrets,
onion credentials or message bodies.

Use a detailed non-interactive view when investigating failures:

```powershell
.\scripts\torchat.ps1 status all -Ui plain -Verbosity detailed
```

## Validation

Targeted repository checks are available under `scripts/internal` and
`scripts/tests`. The release validation entrypoint is:

```powershell
.\scripts\release\validate-torchat-0-1.ps1
```

Run expensive integration, Docker and real-Tor scenarios intentionally; they
are not required for every local code edit.
