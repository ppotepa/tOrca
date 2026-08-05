import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:torchat_mobile/platform/profile_reset_service.dart';

final class DesktopProfileResetService implements ProfileResetService {
  const DesktopProfileResetService({required this.stopRuntime});

  final Future<void> Function() stopRuntime;

  @override
  Future<void> resetLocalProfile() async {
    await stopRuntime();
    final executable = _findNativeHost();
    final arguments = <String>['--reset-profile'];
    final identity = Platform.environment['TORCHAT_IDENTITY_FILE']?.trim();
    final torData = Platform.environment['TORCHAT_TOR_DATA_DIR']?.trim();
    if (identity != null && identity.isNotEmpty) {
      arguments.addAll(<String>['--identity-file', identity]);
    }
    if (torData != null && torData.isNotEmpty) {
      arguments.addAll(<String>['--tor-data-dir', torData]);
    }

    final result = await Process.run(
      executable,
      arguments,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw StateError(
        stderr.isEmpty
            ? 'Torca profile reset failed with code ${result.exitCode}.'
            : 'Torca profile reset failed: $stderr',
      );
    }

    final preferences = await SharedPreferences.getInstance();
    final cleared = await preferences.clear();
    if (!cleared) {
      throw StateError('Torca profile was reset, but UI preferences remained.');
    }
  }

  String _findNativeHost() {
    final configured = Platform.environment['TORCHAT_DESKTOP_PATH']?.trim();
    if (configured != null && configured.isNotEmpty) {
      if (!File(configured).existsSync()) {
        throw StateError('Configured Torca desktop host does not exist.');
      }
      return configured;
    }

    final names = Platform.isWindows
        ? const <String>['torchat-desktop.exe']
        : const <String>['torchat-desktop'];
    final roots = <String>[
      Directory.current.path,
      Directory.current.parent.path,
    ];
    for (final root in roots) {
      for (final name in names) {
        for (final relative in <String>[
          'target/release/$name',
          'target/debug/$name',
          'desktop/target/release/$name',
          'desktop/target/debug/$name',
        ]) {
          final candidate = File('$root${Platform.pathSeparator}$relative');
          if (candidate.existsSync()) return candidate.path;
        }
      }
    }
    throw StateError(
      'Torca desktop engine host was not found; build the Windows runtime first.',
    );
  }
}
