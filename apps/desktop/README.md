# Desktop application

`native/` owns the Windows host process, Tor runtime, secrets, and engine
bridge. `flutter/` owns the Windows shell and desktop platform adapters; its
feature presentation is shared where possible through the Flutter UI package.
