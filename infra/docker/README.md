# Docker development

From the repository root:

Set the single development endpoint in `infra/config/dev.env`. The same file
is consumed by the Android deploy and Docker verification scripts.

Automated start/rebuild and verification:

```powershell
.\scripts\start-dev.ps1
.\scripts\start-dev.ps1 -Rebuild
.\scripts\rebuild-dev.ps1
```

The first command still uses Compose's incremental `--build`; `-Rebuild`
explicitly runs the build stage first. The script preserves the PostgreSQL
named volume.
`rebuild-dev.ps1` additionally verifies the complete Rust/Flutter codebase,
builds the Android APK, force-recreates all containers and checks `/health`
through the v3 onion. Its fast backend-only form is:

```powershell
.\scripts\rebuild-dev.ps1 -SkipChecks -SkipMobileBuild
```

Use `docker compose -f infra/docker/compose.dev.yml down -v` only when you
intentionally want to destroy the development database.

Health check:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/health
```

The mobile APK is deployed with `scripts/deploy-android.ps1`; Wi-Fi is used
only for ADB discovery/install. Relay traffic remains onion/Tor traffic.
This Compose file is development-only. It uses a normal named volume and a
local database password. Production must use the encrypted host filesystem
and Docker secrets described in `docs/DEPLOYMENT.md`.
# Development Docker

Local development:

```powershell
docker compose -f infra/docker/compose.dev.yml up --build
```

Android deployment is performed with `scripts/deploy-android.ps1`. Wi-Fi is
used only for ADB installation; the application connects to the configured
onion address through Tor.
