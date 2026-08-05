# `apps/desktop/flutter/`

Desktop Flutter composition root. It delegates shared application composition
to the cross-platform runner and injects the desktop runtime, window
lifecycle, notification, autostart, and navigation adapters from
`lib/platform/desktop/`. Shared widgets belong to
`packages/torchat-flutter-ui`.

## Windows build prerequisites

Windows Flutter builds create plugin links under `windows/flutter/ephemeral`.
The Windows account running the build must have Developer Mode enabled or
the `SeCreateSymbolicLinkPrivilege` permission. The repository and Flutter
cache should be on a local NTFS volume. Verify the runner with:

```powershell
scripts\torchat.ps1 build windows -BuildPolicy rebuild
scripts\release\validate-torchat-0-1.ps1 -Target windows
```

If Flutter reports `ERROR_INVALID_FUNCTION` while creating a plugin link,
the failure is an operating-system permission/filesystem issue, not a
desktop application path or dependency failure.
