import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'client_runtime.dart';
import 'core/runtime/runtime_arguments.dart';
import 'core/runtime/runtime_bridge_base.dart';
import 'core/runtime/runtime_contract.dart';
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
        Platform.environment['TORCHAT_DESKTOP_PATH'] ?? _findRuntime();
    // The Rust sidecar contains the onion captured during its build. Passing
    // an environment value is deliberately only an explicit development
    // override; the desktop client must remain usable without a LAN/runtime
    // address being injected by Flutter.
    final server =
        Platform.environment['TORCHAT_ONION_URL'] ??
        Platform.environment['TORCHAT_SERVER_URL'];
    final args = ['--stdio-engine'];
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
    return File(
      '${directory.path}/desktop.log',
    ).openWrite(mode: FileMode.append);
  }

  int _nextRunNumber(Directory dateDirectory) {
    final runs = dateDirectory
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map(
          (entry) => entry.uri.pathSegments.lastWhere(
            (segment) => segment.isNotEmpty,
            orElse: () => '',
          ),
        )
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
        ? ['torchat-desktop.exe']
        : ['torchat-desktop'];
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
      'TorChat desktop engine host not found; run torchat build --target windows',
    );
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    final frame = EngineLine.parse(line);
    switch (frame) {
      case EngineResponseLine(:final response):
        final completer = _pending.remove(response.requestId);
        if (completer == null) return;
        if (response.ok) {
          completer.complete(response.result);
        } else {
          completer.completeError(
            StateError(
              response.errorMessage ??
                  response.errorCode ??
                  'Client engine request failed',
            ),
          );
        }
      case EngineRuntimeEventLine(:final payload):
        try {
          final event = payload.runtimeEvent();
          _events.add(event);
          if (event is RuntimeErrorEvent) {
            _failPending(StateError(event.message));
          }
        } catch (error) {
          _events.add(RuntimeErrorEvent(error.toString()));
        }
      case final EngineConnectionLine connection:
        _events.add(connection.runtimeEvent());
      case EngineNotificationLine(:final notification):
        _events.add(
          NotificationRequestedEvent(
            id: notification[EngineContract.id]?.toString() ?? '',
            title: notification[EngineContract.title]?.toString() ?? 'TorChat',
            body: notification[EngineContract.body]?.toString() ?? '',
            conversationId: notification[EngineContract.conversationId]
                ?.toString(),
          ),
        );
      case EngineLogLine(:final log):
        final level = log['level']?.toString() ?? '';
        final message = log['message']?.toString() ?? '';
        _events.add(
          RuntimeLogEvent(level.isEmpty ? message : '[$level] $message'),
        );
      case EngineFatalLine(:final error):
        final code = error['code']?.toString() ?? 'engine_fatal';
        final message = error['message']?.toString() ?? 'Client engine failed';
        final failure = StateError('$code: $message');
        _failPending(failure);
        _events.add(RuntimeErrorEvent(failure.toString()));
      case EngineParseErrorLine(:final error):
        _events.add(RuntimeErrorEvent(error.toString()));
    }
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }

  void _failAll(Object error) {
    _failPending(error);
    _process = null;
    _log('FAIL $error');
    _events.add(RuntimeErrorEvent(error.toString()));
  }

  Map<String, Object?> _engineCommand(
    String method,
    RuntimeArguments arguments,
  ) {
    final params = arguments.toMap();
    String text(String key) => params[key]?.toString() ?? '';
    return switch (method) {
      EngineContract.bootstrap => {
        EngineContract.type: EngineContract.commandBootstrap,
      },
      EngineContract.connect => {
        EngineContract.type: EngineContract.commandConnect,
      },
      EngineContract.getIdentity => {
        EngineContract.type: EngineContract.commandGetIdentity,
      },
      EngineContract.getProfile => {
        EngineContract.type: EngineContract.commandGetProfile,
      },
      EngineContract.pairingInbox => {
        EngineContract.type: EngineContract.commandPairingInbox,
      },
      EngineContract.pairingOutbox => {
        EngineContract.type: EngineContract.commandPairingOutbox,
      },
      EngineContract.listContacts => {
        EngineContract.type: EngineContract.commandListContacts,
      },
      EngineContract.listConversations => {
        EngineContract.type: EngineContract.commandListConversations,
      },
      EngineContract.listMessages => {
        EngineContract.type: EngineContract.commandListMessages,
        EngineContract.commandConversationId: text(EngineContract.argId),
      },
      EngineContract.setNickname => {
        EngineContract.type: EngineContract.commandSetNickname,
        EngineContract.nickname: text(EngineContract.nickname),
      },
      EngineContract.refreshPairingCode => {
        EngineContract.type: EngineContract.commandRefreshPairingCode,
      },
      EngineContract.submitPairingCode => {
        EngineContract.type: EngineContract.commandSubmitPairingCode,
        EngineContract.code: text(EngineContract.code),
      },
      EngineContract.acceptPairing => {
        EngineContract.type: EngineContract.commandAcceptPairing,
        EngineContract.commandPairingId: text(EngineContract.argPairingId),
      },
      EngineContract.rejectPairing => {
        EngineContract.type: EngineContract.commandRejectPairing,
        EngineContract.commandPairingId: text(EngineContract.argPairingId),
      },
      EngineContract.archivePairing => {
        EngineContract.type: EngineContract.commandArchivePairing,
        EngineContract.commandPairingId: text(EngineContract.argPairingId),
      },
      EngineContract.cancelPairing => {
        EngineContract.type: EngineContract.commandCancelPairing,
        EngineContract.commandPairingId: text(EngineContract.argPairingId),
      },
      EngineContract.verifyContact => {
        EngineContract.type: EngineContract.commandVerifyContact,
        EngineContract.commandInstallationId: text(
          EngineContract.argInstallationId,
        ),
      },
      EngineContract.updateContactSettings => {
        EngineContract.type: EngineContract.commandUpdateContactSettings,
        EngineContract.commandInstallationId: text(
          EngineContract.argInstallationId,
        ),
        if (params[EngineContract.localAlias] != null)
          EngineContract.localAlias: text(EngineContract.localAlias),
        EngineContract.muted: params[EngineContract.muted] == true,
        EngineContract.blocked: params[EngineContract.blocked] == true,
      },
      EngineContract.startConversation => {
        EngineContract.type: EngineContract.commandStartConversation,
        EngineContract.commandContactId: text(EngineContract.argContactId),
      },
      EngineContract.openConversation => {
        EngineContract.type: EngineContract.commandOpenConversation,
        EngineContract.commandConversationId: text(EngineContract.argId),
      },
      EngineContract.closeConversation => {
        EngineContract.type: EngineContract.commandCloseConversation,
      },
      EngineContract.sendMessage => {
        EngineContract.type: EngineContract.commandSendMessage,
        EngineContract.commandConversationId: text(EngineContract.argId),
        EngineContract.body: text(EngineContract.argText),
        if (params[EngineContract.argReplyToMessageId] != null)
          EngineContract.commandReplyToMessageId: text(
            EngineContract.argReplyToMessageId,
          ),
      },
      EngineContract.retryMessage => {
        EngineContract.type: EngineContract.commandRetryMessage,
        EngineContract.messageId: text(EngineContract.messageId),
      },
      EngineContract.deleteMessageLocal => {
        EngineContract.type: EngineContract.commandDeleteMessageLocal,
        EngineContract.messageId: text(EngineContract.messageId),
      },
      EngineContract.setTyping => {
        EngineContract.type: EngineContract.commandSetTyping,
        EngineContract.commandConversationId: text(
          EngineContract.conversationId,
        ),
        EngineContract.typing: params[EngineContract.typing] == true,
      },
      EngineContract.setPresence => {
        EngineContract.type: EngineContract.commandSetPresence,
        EngineContract.online: params[EngineContract.online] == true,
      },
      EngineContract.sendReadReceipts => {
        EngineContract.type: EngineContract.commandSendReadReceipts,
        EngineContract.commandConversationId: text(EngineContract.argId),
      },
      EngineContract.platformFact => {
        EngineContract.type: EngineContract.commandPlatformFact,
        EngineContract.fact: params[EngineContract.fact],
      },
      EngineContract.shutdown => {
        EngineContract.type: EngineContract.commandShutdown,
      },
      _ => throw UnsupportedError('Unsupported client engine method: $method'),
    };
  }

  Future<Object?> _call(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]) async {
    await _ensureProcess();
    final id = (++_nextId).toString();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final request = {
      EngineContract.requestId: id,
      EngineContract.command: _engineCommand(method, params),
    };
    _log('STDIN ${jsonEncode(request)}');
    _process!.stdin.writeln(jsonEncode(request));
    return completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Client engine command timed out: $method');
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
