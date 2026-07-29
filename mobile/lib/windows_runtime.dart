import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'client_runtime.dart';
import 'core/runtime/runtime_arguments.dart';
import 'core/runtime/runtime_bridge_base.dart';
import 'core/runtime/runtime_line.dart';
import 'mobile_bridge.dart';

/// JSON-lines bridge to the Rust runtime on Windows/Linux desktop.
/// The Rust process owns Tor, identity, MLS and the encrypted local store.
class WindowsRuntime extends Object
    with RuntimeBridgeMethods
    implements RuntimeCallBridge {
  WindowsRuntime();
  Process? _process;
  IOSink? _logSink;
  final _events = StreamController<RuntimeEvent>.broadcast();
  final _pending = <String, Completer<Object?>>{};
  int _nextId = 0;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  Future<void> _ensureProcess() async {
    if (_process != null) return;
    final executable =
        Platform.environment['TORCHAT_RUNTIME_PATH'] ?? _findRuntime();
    // The Rust sidecar contains the onion captured during its build. Passing
    // an environment value is deliberately only an explicit development
    // override; the desktop client must remain usable without a LAN/runtime
    // address being injected by Flutter.
    final server =
        Platform.environment['TORCHAT_ONION_URL'] ??
        Platform.environment['TORCHAT_SERVER_URL'];
    final args = ['--stdio-runtime'];
    if (server != null && server.isNotEmpty) {
      args.addAll(['--server-url', server]);
    }
    final tor = Platform.environment['TORCHAT_TOR_BINARY'];
    final torData = Platform.environment['TORCHAT_TOR_DATA_DIR'];
    if (tor != null && tor.isNotEmpty) args.addAll(['--tor-binary', tor]);
    if (torData != null && torData.isNotEmpty) {
      args.addAll(['--tor-data-dir', torData]);
    }
    final identity = Platform.environment['TORCHAT_IDENTITY_FILE'];
    if (identity != null && identity.isNotEmpty) {
      args.addAll(['--identity-file', identity]);
    }
    final process = await Process.start(executable, args, runInShell: false);
    _process = process;
    _logSink = _openLogSink();
    _log('START $executable ${args.join(' ')}');
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _log('STDOUT $line');
            _onLine(line);
          },
          onDone: () {
            _log('STOP runtime stdout closed');
            _failAll(StateError('TorChat runtime stopped'));
          },
        );
    process.stderr.transform(utf8.decoder).listen((value) {
      if (value.trim().isNotEmpty) {
        final text = value.trim();
        _log('STDERR $text');
        _events.add(RuntimeLogEvent(text));
      }
    });
  }

  IOSink? _openLogSink() {
    final root = Platform.environment['TORCHAT_LOG_DIR'];
    if (root == null || root.isEmpty) return null;
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final dateDirectory = Directory('${Directory(root).path}/$date')
      ..createSync(recursive: true);
    final runNumber = _nextRunNumber(dateDirectory);
    final directory = Directory(
      '${dateDirectory.path}/run-${runNumber.toString().padLeft(4, '0')}',
    )..createSync(recursive: true);
    return File('${directory.path}/desktop.log').openWrite(
      mode: FileMode.append,
    );
  }

  int _nextRunNumber(Directory dateDirectory) {
    final runs = dateDirectory
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map((entry) => entry.uri.pathSegments.lastWhere(
              (segment) => segment.isNotEmpty,
              orElse: () => '',
            ))
        .where((name) => RegExp(r'^run-\d{4}$').hasMatch(name))
        .map((name) => int.tryParse(name.substring(4)) ?? 0)
        .toList();
    if (runs.isEmpty) return 1;
    runs.sort();
    return runs.last + 1;
  }

  void _log(String message) {
    final sink = _logSink;
    if (sink == null) return;
    sink.writeln('${DateTime.now().toIso8601String()} $message');
  }

  String _findRuntime() {
    final names = Platform.isWindows
        ? ['torchat-desktop.exe', 'torchat-runtime.exe']
        : ['torchat-desktop', 'torchat-runtime'];
    final roots = [Directory.current.path, '${Directory.current.path}/..'];
    for (final root in roots) {
      for (final name in names) {
        final candidates = [
          '$root/target/debug/$name',
          '$root/target/release/$name',
          '$root/desktop/target/debug/$name',
          '$root/desktop/target/release/$name',
        ];
        for (final path in candidates) {
          if (File(path).existsSync()) return path;
        }
      }
    }
    throw StateError(
      'Rust runtime not found; run torchat build --target windows',
    );
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    try {
      final frame = RuntimeLine.parse(line);
      switch (frame) {
        case RuntimeResponseLine(:final response):
          if (_pending.containsKey(response.id)) {
            final completer = _pending.remove(response.id)!;
            if (response.ok) {
              completer.complete(response.result);
            } else {
              completer.completeError(
                StateError(response.error ?? 'Runtime error'),
              );
            }
          }
        case RuntimeEventLine(:final response):
          if (response.isRuntimeErrorEvent) {
            final error = StateError(response.error ?? 'Runtime error');
            _events.add(response.payload.runtimeEvent());
            if (_pending.isNotEmpty) {
              for (final completer in _pending.values) {
                completer.completeError(error);
              }
              _pending.clear();
            }
          } else {
            _events.add(response.payload.runtimeEvent());
          }
        case RuntimeParseErrorLine(:final error):
          _events.add(RuntimeErrorEvent(error.toString()));
      }
    } catch (error) {
      _events.add(RuntimeErrorEvent(error.toString()));
    }
  }

  void _failAll(Object error) {
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    _process = null;
    _log('FAIL $error');
    _events.add(RuntimeErrorEvent(error.toString()));
  }

  Future<Object?> _call(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]) async {
    await _ensureProcess();
    final id = (++_nextId).toString();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final request = {'id': id, 'method': method, 'params': params.toMap()};
    _log('STDIN ${jsonEncode(request)}');
    _process!.stdin.writeln(jsonEncode(request));
    return completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Runtime command timed out: $method');
      },
    );
  }

  @override
  Future<Object?> callRuntime(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]) async => _call(method, params);
}

ClientRuntime createPlatformRuntime() =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS
    ? WindowsRuntime()
    : const MobileBridge();
