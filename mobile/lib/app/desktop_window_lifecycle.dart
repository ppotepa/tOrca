import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const _windowWidthKey = 'torchat.desktop.window.width';
const _windowHeightKey = 'torchat.desktop.window.height';
const _windowXKey = 'torchat.desktop.window.x';
const _windowYKey = 'torchat.desktop.window.y';

bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class DesktopWindowLifecycle with WindowListener {
  DesktopWindowLifecycle._();

  static final DesktopWindowLifecycle instance = DesktopWindowLifecycle._();

  static Future<void>? _initialization;
  Timer? _persistDebounce;
  bool _allowClose = false;

  static Future<void> initialize() {
    if (!isDesktopPlatform) return Future<void>.value();
    return _initialization ??= instance._initialize();
  }

  Future<void> _initialize() async {
    await windowManager.ensureInitialized();
    final preferences = await SharedPreferences.getInstance();
    final storedWidth = preferences.getDouble(_windowWidthKey);
    final storedHeight = preferences.getDouble(_windowHeightKey);
    final storedX = preferences.getDouble(_windowXKey);
    final storedY = preferences.getDouble(_windowYKey);

    final size = Size(
      (storedWidth ?? 1280).clamp(900, 3840).toDouble(),
      (storedHeight ?? 820).clamp(640, 2160).toDouble(),
    );
    final options = WindowOptions(
      size: size,
      minimumSize: const Size(900, 640),
      center: storedX == null || storedY == null,
      title: 'TorChat',
      backgroundColor: Colors.transparent,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      if (storedX != null && storedY != null) {
        await windowManager.setPosition(Offset(storedX, storedY));
      }
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  Future<void> showWindow() async {
    if (!isDesktopPlatform) return;
    await initialize();
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
  }

  Future<void> exitApplication() async {
    if (!isDesktopPlatform) return;
    _allowClose = true;
    await _persistNow();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void onWindowClose() {
    if (_allowClose) return;
    // Until a packaged tray icon is available, minimizing is safer than
    // hiding the only window and leaving no user-accessible restore path.
    unawaited(windowManager.minimize());
  }

  @override
  void onWindowMove() => _schedulePersist();

  @override
  void onWindowResize() => _schedulePersist();

  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 350), _persistNow);
  }

  Future<void> _persistNow() async {
    if (!isDesktopPlatform) return;
    final maximized = await windowManager.isMaximized();
    final minimized = await windowManager.isMinimized();
    if (maximized || minimized) return;
    final size = await windowManager.getSize();
    final position = await windowManager.getPosition();
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setDouble(_windowWidthKey, size.width),
      preferences.setDouble(_windowHeightKey, size.height),
      preferences.setDouble(_windowXKey, position.dx),
      preferences.setDouble(_windowYKey, position.dy),
    ]);
  }
}
