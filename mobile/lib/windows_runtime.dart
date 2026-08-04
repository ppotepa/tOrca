import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'client_runtime.dart';
import 'core/runtime/runtime_arguments.dart';
import 'core/runtime/runtime_bridge_base.dart';
import 'core/runtime/runtime_contract.dart';
import 'core/runtime/runtime_line.dart';
import 'core/runtime/operation_journal.dart';
import 'mobile_bridge.dart';

/// JSON-lines bridge to the Rust runtime on Windows/Linux desktop.
/// The Rust process owns Tor, identity, MLS and the encrypted local store.
class WindowsRuntime extends Object
    with RuntimeBridgeMethods
    implements RuntimeCallBridge, RuntimeDisposable {
  WindowsRuntime();

  Process? _process;
  IOSink? _logSink;
  Future<void>? _startInFlight;
  Future<void>? _bootstrapInFlight;
  bool _stopping = false;
  int _processGeneration = 0;
  int? _stoppingGeneration;
  Future<OperationJournal>? _operationJournal;
  final _events = StreamController<RuntimeEvent>.broadcast();
  final _pending = <String, Completer<Object?>>{};
  int _nextId = 0;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  @override
  Future<void> disposeRuntime() async {
    final process = _process;
    if (process == null) {
      _process = null;
      return;
    }
    _pending.clear();
    _process = null;
    _processGeneration += 1;
    try {
      process.kill();
    } catch (_) {}
  }

  Future<void> _ensureProcess() async {
    final currentProcess = _process;
    if (currentProcess != null) {
      final bootstrap = _bootstrapInFlight;
      if (bootstrap != null) await bootstrap;
      return;
    }

    final currentStart = _startInFlight;
    if (currentStart != null) {
      await currentStart;
      return;
    }

    final start = _startProcess();
    _startInFlight = start;
    try {
      await start;
    } finally {
      if (identical(_startInFlight, start)) _startInFlight = null;
    }
  }

  Future<void> _startProcess() async {
    final executable =
        Platform.environment['TORCHAT_DESKTOP_PATH'] ?? _findRuntime();
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
    final generation = ++_processGeneration;
    final logSink = _openLogSink();
    _process = process;
    _logSink = logSink;
    _stopping = false;
    _stoppingGeneration = null;
    _writeLog(
      logSink,
      generation,
      'START pid=${process.pid} $executable ${args.join(' ')}',
    );

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _writeLog(logSink, generation, 'STDOUT ${_wireSummary(line)}');
            if (!_owns(process, generation)) return;
            _onLine(line);
          },
          onError: (Object error, StackTrace stackTrace) {
            _writeLog(logSink, generation, 'STDOUT_ERROR $error');
            if (!_owns(process, generation)) return;
            _failCurrent(process, generation, error, stackTrace);
          },
          onDone: () {
            final expected = _stopping && _stoppingGeneration == generation;
            _writeLog(
              logSink,
              generation,
              'STOP pid=${process.pid} stdout_closed expected=$expected',
            );
            if (!_owns(process, generation)) {
              unawaited(logSink?.close());
              return;
            }
            if (expected) {
              _process = null;
              _logSink = null;
              _bootstrapInFlight = null;
              _stopping = false;
              _stoppingGeneration = null;
              unawaited(logSink?.close());
            } else {
              _failCurrent(
                process,
                generation,
                StateError('TorChat runtime stopped unexpectedly'),
                StackTrace.current,
              );
            }
          },
        );

    process.stderr.transform(utf8.decoder).listen((value) {
      final text = value.trim();
      if (text.isEmpty) return;
      _writeLog(logSink, generation, 'STDERR $text');
      if (_owns(process, generation)) {
        _events.add(RuntimeLogEvent(text));
      }
    });

    final bootstrap = _sendRequest(
      EngineContract.bootstrap,
      RuntimeArguments.empty,
      process: process,
      generation: generation,
    ).then<void>((_) {});
    _bootstrapInFlight = bootstrap;
    try {
      await bootstrap.timeout(const Duration(seconds: 30));
      _writeLog(logSink, generation, 'READY bootstrap_complete');
    } catch (error, stackTrace) {
      if (_owns(process, generation)) {
        process.kill();
        _failCurrent(process, generation, error, stackTrace);
      }
      rethrow;
    } finally {
      if (identical(_bootstrapInFlight, bootstrap)) {
        _bootstrapInFlight = null;
      }
    }
  }

  bool _owns(Process process, int generation) =>
      identical(_process, process) && _processGeneration == generation;

  void _failCurrent(
    Process process,
    int generation,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!_owns(process, generation)) return;
    final sink = _logSink;
    _failPending(error, stackTrace);
    _process = null;
    _logSink = null;
    _bootstrapInFlight = null;
    _stopping = false;
    _stoppingGeneration = null;
    _writeLog(sink, generation, 'FAIL pid=${process.pid} $error');
    unawaited(sink?.close());
    _events.add(RuntimeErrorEvent(error.toString()));
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

  void _writeLog(IOSink? sink, int generation, String message) {
    if (sink == null) return;
    final deployRunId = Platform.environment['TORCHAT_DEPLOY_RUN_ID']?.trim();
    sink.writeln(
      '${DateTime.now().toIso8601String()} '
      'deployRunId=${deployRunId?.isNotEmpty == true ? deployRunId : '-'} '
      'runtimeGeneration=$generation processRole=desktop-engine $message',
    );
  }

  String _wireSummary(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        return 'non_object bytes=${utf8.encode(line).length}';
      }
      final type = decoded[EngineContract.type]?.toString() ?? 'unknown';
      final requestId = decoded[EngineContract.requestId]?.toString();
      final runtime = decoded[EngineContract.event];
      final runtimeType = runtime is Map
          ? runtime[EngineContract.type]?.toString()
          : null;
      return [
        'type=$type',
        if (requestId != null && requestId.isNotEmpty) 'requestId=$requestId',
        if (runtimeType != null && runtimeType.isNotEmpty)
          'runtimeType=$runtimeType',
      ].join(' ');
    } catch (_) {
      return 'unparseable bytes=${utf8.encode(line).length}';
    }
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
    if (line.trim().isEmpty) return;
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
            _failPending(StateError(event.message), StackTrace.current);
          }
        } catch (error) {
          _events.add(RuntimeErrorEvent(error.toString()));
        }
      case EngineConnectionLine():
        // The engine connection event describes the application/relay
        // connection state, not the local Tor process.  In particular,
        // TorEndpointAvailable deliberately leaves the relay connection in
        // `disconnected` until the relay session is established.  Translating
        // that event into TorStatusEvent would therefore turn a ready Tor
        // process back into `offline` and block the peer listener/onion
        // readiness chain.  Tor status is emitted explicitly by the engine
        // through `tor_status` and `transport_status_changed` events.
        break;
      case EngineNotificationLine(:final notification):
        _events.add(
          NotificationRequestedEvent(
            id: notification[EngineContract.id]?.toString() ?? '',
            kind: NotificationKind.fromWire(notification[EngineContract.kind]),
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
        _failPending(failure, StackTrace.current);
        _events.add(RuntimeErrorEvent(failure.toString()));
      case EngineParseErrorLine(:final error):
        _events.add(RuntimeErrorEvent(error.toString()));
    }
  }

  void _failPending(Object error, [StackTrace? stackTrace]) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace ?? StackTrace.current);
      }
    }
    _pending.clear();
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
      EngineContract.getApplicationSnapshot => {
        EngineContract.type: EngineContract.commandGetApplicationSnapshot,
      },
      EngineContract.listPairings => {
        EngineContract.type: EngineContract.commandListPairings,
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
      EngineContract.getPeerEndpoint => {
        EngineContract.type: EngineContract.commandGetPeerEndpoint,
      },
      EngineContract.getStartupReadiness => {
        EngineContract.type: EngineContract.commandGetStartupReadiness,
      },
      EngineContract.retryPeerConnection => {
        EngineContract.type: EngineContract.commandRetryPeerConnection,
        EngineContract.commandInstallationId: text(
          EngineContract.argInstallationId,
        ),
      },
      EngineContract.rotatePeerEndpoint => {
        EngineContract.type: EngineContract.commandRotatePeerEndpoint,
      },
      EngineContract.getContactEndpointCapability => {
        EngineContract.type: EngineContract.commandGetContactEndpointCapability,
        EngineContract.commandInstallationId: text(
          EngineContract.argInstallationId,
        ),
      },
      EngineContract.rotateContactEndpointCapability => {
        EngineContract.type:
            EngineContract.commandRotateContactEndpointCapability,
        EngineContract.commandInstallationId: text(
          EngineContract.argInstallationId,
        ),
      },
      EngineContract.revokeContactEndpointCapability => {
        EngineContract.type:
            EngineContract.commandRevokeContactEndpointCapability,
        EngineContract.commandInstallationId: text(
          EngineContract.argInstallationId,
        ),
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
        if (params[EngineContract.transportPolicy] != null)
          EngineContract.transportPolicy: text(EngineContract.transportPolicy),
      },
      EngineContract.removeRelationship => {
        EngineContract.type: EngineContract.commandRequestRelationshipRemoval,
        EngineContract.commandInstallationId: text(
          EngineContract.argInstallationId,
        ),
        'preserveHistory': params['preserveHistory'] == true,
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
      EngineContract.retryDeadLetter => {
        EngineContract.type: EngineContract.commandRetryDeadLetter,
        EngineContract.kind: text(EngineContract.kind),
        EngineContract.id: text(EngineContract.id),
      },
      EngineContract.listDeadLetters => {
        EngineContract.type: EngineContract.commandListDeadLetters,
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
      EngineContract.setConversationFocus => {
        EngineContract.type: EngineContract.commandSetConversationFocus,
        EngineContract.commandConversationId: text(
          EngineContract.conversationId,
        ),
        EngineContract.focused: params[EngineContract.focused] == true,
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

  Future<Object?> _sendRequest(
    String method,
    RuntimeArguments params, {
    required Process process,
    required int generation,
  }) async {
    if (!_owns(process, generation)) {
      return Future<Object?>.error(
        StateError('Desktop runtime generation changed before command send'),
      );
    }
    final id = (++_nextId).toString();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final command = _engineCommand(method, params);
    final nonIdempotent = method == EngineContract.refreshPairingCode;
    if (nonIdempotent) {
      final request = {
        EngineContract.requestId: id,
        EngineContract.command: command,
      };
      _writeLog(
        _logSink,
        generation,
        'STDIN requestId=$id command=${command[EngineContract.type] ?? method}',
      );
      try {
        process.stdin.writeln(jsonEncode(request));
      } catch (error, stackTrace) {
        _pending.remove(id);
        completer.completeError(error, stackTrace);
      }
      return completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          _pending.remove(id);
          throw TimeoutException('Client engine command timed out: $method');
        },
      );
    }
    // The complete canonical command payload is part of the journal key.
    // Target-only keys incorrectly reused a completed command for a later
    // mutation against the same conversation/contact.
    final stablePayloadKey = jsonEncode(_canonicalizeCommand(params.toMap()));
    final journal = _operationJournal ??= SharedPreferences.getInstance().then(
      OperationJournal.new,
    );
    final journalValue = await journal;
    final commandId = await journalValue.commandId(
      operation: method,
      stableId: stablePayloadKey,
      payloadHash: stablePayloadKey,
    );
    final operationKey = '$method:$stablePayloadKey';
    await journalValue.markSubmitted(operationKey);
    final request = {
      EngineContract.requestId: id,
      EngineContract.commandId: commandId,
      EngineContract.command: command,
    };
    if (method == EngineContract.shutdown) {
      _stopping = true;
      _stoppingGeneration = generation;
    }
    _writeLog(
      _logSink,
      generation,
      'STDIN requestId=$id command=${command[EngineContract.type] ?? method}',
    );
    try {
      process.stdin.writeln(jsonEncode(request));
    } catch (error, stackTrace) {
      _pending.remove(id);
      completer.completeError(error, stackTrace);
    }
    return completer.future
        .timeout(
          const Duration(seconds: 45),
          onTimeout: () {
            _pending.remove(id);
            throw TimeoutException('Client engine command timed out: $method');
          },
        )
        .then((value) async {
          await journalValue.markCompleted(operationKey);
          return value;
        });
  }

  dynamic _canonicalizeCommand(dynamic value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return <String, dynamic>{
        for (final entry in entries)
          entry.key.toString(): _canonicalizeCommand(entry.value),
      };
    }
    if (value is List) {
      return value.map(_canonicalizeCommand).toList(growable: false);
    }
    return value;
  }

  Future<Object?> _call(
    String method, [
    RuntimeArguments params = RuntimeArguments.empty,
  ]) async {
    await _ensureProcess();
    final process = _process;
    final generation = _processGeneration;
    if (process == null) {
      throw StateError('Desktop runtime is not available after bootstrap');
    }
    return _sendRequest(
      method,
      params,
      process: process,
      generation: generation,
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
    : MobileBridge();
