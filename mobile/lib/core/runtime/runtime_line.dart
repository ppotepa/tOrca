import 'dart:convert';

import '../models/domain.dart';
import '../models/generated/runtime_models.g.dart';
import 'runtime_contract.dart';
import 'runtime_payload.dart';
import 'runtime_response.dart';

sealed class EngineLine {
  const EngineLine();

  factory EngineLine.parse(String line) {
    try {
      return EngineLine.fromDynamic(jsonDecode(line));
    } catch (error) {
      return EngineParseErrorLine(error);
    }
  }

  factory EngineLine.fromDynamic(Object? value) {
    if (value is! Map) {
      return EngineParseErrorLine(
        const FormatException('engine line must be a JSON object'),
      );
    }
    final event = GeneratedEngineEvent.fromDynamic(value);
    return switch (event.type) {
      EngineContract.eventResponse => EngineResponseLine(
        EngineResponse.fromDynamic(event.envelope),
      ),
      EngineContract.eventRuntime => EngineRuntimeEventLine(
        RuntimePayload.fromMap(event.objectValue(EngineContract.event)),
      ),
      EngineContract.eventConnection => EngineConnectionLine(
        event.objectValue(EngineContract.snapshot),
      ),
      EngineContract.eventNotificationRequested => EngineNotificationLine(
        event.objectValue(EngineContract.notification),
      ),
      EngineContract.eventLog => EngineLogLine(
        event.objectValue(EngineContract.log),
      ),
      EngineContract.eventFatal => EngineFatalLine(
        event.objectValue(EngineContract.error),
      ),
      _ => throw StateError('validated engine event type is not handled'),
    };
  }
}

final class EngineResponseLine extends EngineLine {
  const EngineResponseLine(this.response);

  final EngineResponse response;
}

final class EngineRuntimeEventLine extends EngineLine {
  const EngineRuntimeEventLine(this.payload);

  final RuntimePayload payload;
}

final class EngineConnectionLine extends EngineLine {
  const EngineConnectionLine(this.snapshot);

  final Map<String, dynamic> snapshot;

  RuntimeEvent runtimeEvent() {
    final stateValue = snapshot[EngineContract.state];
    var state =
        stateValue?.toString() ?? EngineContract.connectionStateDisconnected;
    var retryAttempt = 0;
    int? retryInMs;
    if (stateValue is Map) {
      final stateMap = Map<String, dynamic>.from(stateValue);
      final backoff = stateMap[EngineContract.backoff];
      if (backoff is Map) {
        final backoffMap = Map<String, dynamic>.from(backoff);
        state = EngineContract.connectionStateBackoff;
        retryAttempt =
            (backoffMap[EngineContract.attempt] as num?)?.toInt() ?? 0;
        retryInMs = (backoffMap[EngineContract.retryInMs] as num?)?.toInt();
      }
    }
    final rawDetail = snapshot[EngineContract.detail]?.toString() ?? '';
    final phase = switch (state) {
      EngineContract.connectionStateWaitingForTor => TransportPhase.starting,
      EngineContract.connectionStateConnecting ||
      EngineContract.connectionStateAuthenticating ||
      EngineContract.connectionStateWaitingForReady =>
        TransportPhase.connecting,
      EngineContract.connectionStateConnected => TransportPhase.connected,
      EngineContract.connectionStateBackoff => TransportPhase.reconnecting,
      EngineContract.connectionStateStopped ||
      EngineContract.connectionStateDisconnected => TransportPhase.offline,
      _ => TransportPhase.error,
    };
    final detail = _connectionDetail(rawDetail, retryInMs);
    return TorStatusEvent(
      RuntimeTorStatus(
        phase: phase,
        label: phase.label,
        detail: detail,
        retryAttempt: retryAttempt,
      ),
    );
  }
}

String _connectionDetail(String detail, int? retryInMs) {
  final trimmed = detail.trim();
  final technical =
      trimmed.isEmpty ||
      trimmed == 'engine actor initialized' ||
      trimmed == 'connect requested' ||
      trimmed == 'platform fact applied' ||
      trimmed == 'relay connected';
  if (technical) return '';
  if (trimmed.startsWith('relay transport error:')) {
    final retry = retryInMs == null ? '' : ' Próba ponownie za ${retryInMs}ms.';
    return 'Relay onion jest chwilowo niedostępny albo aplikacja ma nieaktualny adres.$retry';
  }
  return retryInMs == null ? trimmed : '$trimmed; retry in ${retryInMs}ms';
}

final class EngineNotificationLine extends EngineLine {
  const EngineNotificationLine(this.notification);

  final Map<String, dynamic> notification;
}

final class EngineLogLine extends EngineLine {
  const EngineLogLine(this.log);

  final Map<String, dynamic> log;
}

final class EngineFatalLine extends EngineLine {
  const EngineFatalLine(this.error);

  final Map<String, dynamic> error;
}

final class EngineParseErrorLine extends EngineLine {
  const EngineParseErrorLine(this.error);

  final Object error;
}
