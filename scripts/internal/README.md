# Internal scripts

`scripts/torchat.ps1` is the only public command entrypoint. Build, deploy,
ABI, staging, cache, and device policy decisions belong in
`scripts/modules/`; internal scripts are validation or low-level technical
helpers invoked by the CLI or CI.

The following historical standalone build implementations were removed because
they duplicated the module implementation and had no callers:

- `build-cache.ps1`
- `build-android-core.ps1`
- `build-clients.ps1`
- `build-desktop-runtime.ps1`

New internal scripts must be classified as a validation gate or a technical
helper and must not become a second public build/deploy interface.
