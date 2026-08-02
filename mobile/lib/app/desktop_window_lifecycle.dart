import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_navigation_intent.dart';

const _windowWidthKey = 'torchat.desktop.window.width';
const _windowHeightKey = 'torchat.desktop.window.height';
const _windowXKey = 'torchat.desktop.window.x';
const _windowYKey = 'torchat.desktop.window.y';
const _singleInstancePort = 49631;
const _activationMessage = 'activate';

bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class DesktopWindowLifecycle with WindowListener, TrayListener {
  DesktopWindowLifecycle._();

  static final DesktopWindowLifecycle instance = DesktopWindowLifecycle._();

  static Future<bool>? _initialization;
  Timer? _persistDebounce;
  ServerSocket? _activationServer;
  bool _allowClose = false;
  bool _trayReady = false;

  static Future<bool> initialize() {
    if (!isDesktopPlatform) return Future<bool>.value(true);
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return Future<bool>.value(true);
    }
    return _initialization ??= instance._initialize();
  }

  Future<bool> _initialize() async {
    if (!await _acquireSingleInstance()) return false;

    try {
      await windowManager.ensureInitialized();
    } on MissingPluginException {
      // A non-Flutter desktop host/test can construct the runtime before the
      // window plugin is attached. Do not block engine or data warmup on UI
      // chrome; the real desktop host will initialize it on the next launch.
      return true;
    }
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
      await _initializeTray();
      await windowManager.show();
      await windowManager.focus();
    });
    return true;
  }

  Future<bool> _acquireSingleInstance() async {
    try {
      _activationServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _singleInstancePort,
        shared: false,
      );
      _activationServer!.listen((socket) {
        socket.cast<List<int>>().transform(utf8.decoder).listen((message) {
          if (message.trim() == _activationMessage) {
            unawaited(showWindow());
          }
        });
      });
      return true;
    } on SocketException {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          _singleInstancePort,
          timeout: const Duration(seconds: 1),
        );
        socket.write(_activationMessage);
        await socket.flush();
        await socket.close();
      } on Object {
        // The first instance may still be starting. The second instance exits
        // rather than starting a competing Tor and storage runtime.
      }
      return false;
    }
  }

  Future<void> _initializeTray() async {
    if (_trayReady) return;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final iconPath = Platform.isWindows
        ? '$executableDirectory${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}windows${Platform.pathSeparator}runner${Platform.pathSeparator}resources${Platform.pathSeparator}app_icon.ico'
        : 'windows/runner/resources/app_icon.ico';

    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('TorChat');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Pokaż TorChat'),
          MenuItem(key: 'settings', label: 'Ustawienia'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Zakończ'),
        ],
      ),
    );
    trayManager.addListener(this);
    _trayReady = true;
  }

  Future<void> showWindow() async {
    if (!isDesktopPlatform) return;
    await windowManager.show();
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
  }

  Future<void> exitApplication() async {
    if (!isDesktopPlatform) return;
    _allowClose = true;
    await _persistNow();
    trayManager.removeListener(this);
    await trayManager.destroy();
    await _activationServer?.close();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'settings':
        unawaited(showWindow());
        DesktopNavigationIntents.openSettings();
      case 'exit':
        unawaited(exitApplication());
    }
  }

  @override
  void onWindowClose() {
    if (_allowClose) return;
    if (_trayReady) {
      unawaited(windowManager.hide());
    } else {
      unawaited(windowManager.minimize());
    }
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
