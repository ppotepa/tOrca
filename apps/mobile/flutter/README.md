# `apps/mobile/flutter/`

This is the Android-oriented Flutter runner. Shared UI is being extracted to
`packages/torchat-flutter-ui`; desktop platform implementations are owned by
`apps/desktop/flutter` and are injected through `lib/platform/platform_services.dart`.

Shared features must not import native bridges directly. Platform-specific
code belongs under `lib/platform/android/`; the remaining desktop workspace
composition is a compatibility layer while it is extracted to the desktop
runner. Shared
runtime DTOs and repositories remain in the shared layer.
