import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'client_runtime.dart';
import 'mobile_bridge.dart';

/// JSON-lines bridge to the Rust runtime on Windows/Linux desktop.
/// The Rust process owns Tor, identity, MLS and the encrypted local store.
class WindowsRuntime implements ClientRuntime {
  WindowsRuntime();
  Process? _process;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<dynamic>>{};
  int _nextId = 0;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<void> _ensureProcess() async {
    if (_process != null) return;
    final executable = Platform.environment['TORCHAT_RUNTIME_PATH'] ??
        _findRuntime();
    final server = Platform.environment['TORCHAT_ONION_URL'] ??
        Platform.environment['TORCHAT_SERVER_URL'];
    if (server == null || server.isEmpty) {
      throw StateError('TORCHAT_ONION_URL is not configured');
    }
    final args = ['--stdio-runtime', '--server-url', server];
    final tor = Platform.environment['TORCHAT_TOR_BINARY'];
    final torData = Platform.environment['TORCHAT_TOR_DATA_DIR'];
    if (tor != null && tor.isNotEmpty) args.addAll(['--tor-binary', tor]);
    if (torData != null && torData.isNotEmpty) args.addAll(['--tor-data-dir', torData]);
    final identity = Platform.environment['TORCHAT_IDENTITY_FILE'];
    if (identity != null && identity.isNotEmpty) args.addAll(['--identity-file', identity]);
    final process = await Process.start(executable, args, runInShell: false);
    _process = process;
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine,
        onDone: () => _failAll(StateError('TorChat runtime stopped')));
    process.stderr.transform(utf8.decoder).listen((value) {
      if (value.trim().isNotEmpty) _events.add({'type': 'runtime_log', 'message': value.trim()});
    });
  }

  String _findRuntime() {
    final names = Platform.isWindows
        ? ['torchat-desktop.exe', 'torchat-runtime.exe']
        : ['torchat-desktop', 'torchat-runtime'];
    final roots = [Directory.current.path, '${Directory.current.path}/..'];
    for (final root in roots) {
      for (final name in names) {
        final candidates = [
          '$root/target/debug/$name', '$root/target/release/$name',
          '$root/desktop/target/debug/$name', '$root/desktop/target/release/$name',
        ];
        for (final path in candidates) {
          if (File(path).existsSync()) return path;
        }
      }
    }
    throw StateError('Rust runtime not found; run torchat build --target windows');
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    try {
      final value = Map<String, dynamic>.from(jsonDecode(line) as Map);
      final id = value['id'] as String?;
      if (id != null && _pending.containsKey(id)) {
        final completer = _pending.remove(id)!;
        if (value['ok'] == true) {
          completer.complete(value['result']);
        } else {
          completer.completeError(StateError(value['error']?.toString() ?? 'Runtime error'));
        }
      } else {
        _events.add(value);
      }
    } catch (error) {
      _events.add({'type': 'runtime_error', 'message': error.toString()});
    }
  }

  void _failAll(Object error) {
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    _process = null;
    _events.add({'type': 'runtime_error', 'message': error.toString()});
  }

  Future<dynamic> _call(String method, [Map<String, dynamic>? params]) async {
    await _ensureProcess();
    final id = (++_nextId).toString();
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _process!.stdin.writeln(jsonEncode({'id': id, 'method': method, 'params': params ?? {}}));
    return completer.future;
  }
  Map<String, dynamic>? _map(dynamic v) => v == null ? null : Map<String, dynamic>.from(v as Map);
  List<Map<String, dynamic>> _list(dynamic v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  @override Future<bool> connect() async => await _call('connect') as bool;
  @override Future<Map<String, dynamic>?> identity() async => _map(await _call('identity'));
  @override Future<Map<String, dynamic>?> refreshPairingCode() async => _map(await _call('refreshPairingCode'));
  @override Future<Map<String, dynamic>> setNickname(String n) async => _map(await _call('setNickname', {'nickname': n})) ?? {};
  @override Future<void> submitPairingCode(String code) async { await _call('submitPairingCode', {'code': code}); }
  @override Future<List<Map<String, dynamic>>> pairingInbox() async => _list(await _call('pairingInbox'));
  @override Future<void> acceptPairing(String id) async { await _call('acceptPairing', {'pairingId': id}); }
  @override Future<void> rejectPairing(String id) async { await _call('rejectPairing', {'pairingId': id}); }
  @override Future<void> verifyContact(String id) async { await _call('verifyContact', {'installationId': id}); }
  @override Future<List<Map<String, dynamic>>> contacts() async => _list(await _call('contacts'));
  @override Future<List<Map<String, dynamic>>> conversations() async => _list(await _call('conversations'));
  @override Future<List<Map<String, dynamic>>> messages(String id) async => _list(await _call('messages', {'id': id}));
  @override Future<void> openConversation(String id) async { await _call('openConversation', {'id': id}); }
  @override Future<void> sendMessage(String id, String text) async { await _call('sendMessage', {'id': id, 'text': text}); }
}

ClientRuntime createPlatformRuntime() => Platform.isWindows || Platform.isLinux || Platform.isMacOS
    ? WindowsRuntime() : const MobileBridge();
