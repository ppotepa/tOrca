# Desktop Flutter adapters

This directory is the ownership boundary for Windows desktop-only Flutter
adapters: runtime process integration, window lifecycle, notifications,
autostart, navigation intents, and desktop composition helpers.

Shared widgets and runtime-facing DTOs belong in `packages/torchat-flutter-ui`.
The Android application must not import code from this directory. The desktop
runner currently delegates its composition root to the mobile Flutter package;
adapter extraction is being completed incrementally while preserving an
acyclic package graph.
