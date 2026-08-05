import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

final class OperationJournal {
  OperationJournal(this._preferences);

  static const _key = 'torchat.operation-command-ids';
  static const maxEntries = 256;
  final SharedPreferences _preferences;

  Future<String> commandId({
    required String operation,
    String? stableId,
    String? payloadHash,
  }) async {
    final key = stableId == null || stableId.isEmpty
        ? null
        : '$operation:$stableId';
    final values = _read();
    if (key != null && values[key]?.commandId.isNotEmpty == true) {
      final record = values[key]!;
      if (payloadHash == null || record.payloadHash == payloadHash) {
        return record.commandId;
      }
      throw StateError('Operation payload changed for existing commandId');
    }
    final id =
        'operation-${DateTime.now().microsecondsSinceEpoch}-${values.length}';
    if (key != null) {
      while (values.length >= maxEntries) {
        values.remove(values.keys.first);
      }
      values[key] = OperationRecord(
        operationId: key,
        commandId: id,
        payloadHash: payloadHash,
        state: OperationState.prepared,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _write(values);
    }
    return id;
  }

  Future<void> markSubmitted(String operation) async {
    await _mark(operation, OperationState.submitted);
  }

  Future<void> markCompleted(String operation) async {
    await _mark(operation, OperationState.completed);
  }

  Future<void> _mark(String operation, OperationState state) async {
    final values = _read();
    final record = values[operation];
    if (record == null) return;
    values[operation] = record.copyWith(
      state: state,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _write(values);
  }

  Map<String, OperationRecord> _read() {
    final raw = _preferences.getString(_key);
    if (raw == null) return <String, OperationRecord>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, OperationRecord>{};
      return decoded.map((key, value) {
        final name = key.toString();
        if (value is String) {
          return MapEntry(name, OperationRecord.legacy(name, value));
        }
        return MapEntry(name, OperationRecord.fromJson(name, value));
      });
    } on FormatException {
      return <String, OperationRecord>{};
    }
  }

  Future<void> _write(Map<String, OperationRecord> values) =>
      _preferences.setString(
        _key,
        jsonEncode(values.map((key, value) => MapEntry(key, value.toJson()))),
      );
}

enum OperationState { prepared, submitted, completed, failedPermanent }

final class OperationRecord {
  const OperationRecord({
    required this.operationId,
    required this.commandId,
    required this.state,
    required this.updatedAt,
    this.payloadHash,
  });

  final String operationId;
  final String commandId;
  final String? payloadHash;
  final OperationState state;
  final int updatedAt;

  factory OperationRecord.legacy(String operationId, String commandId) =>
      OperationRecord(
        operationId: operationId,
        commandId: commandId,
        state: OperationState.submitted,
        updatedAt: 0,
      );

  factory OperationRecord.fromJson(String operationId, Object? value) {
    final json = value is Map ? value : const <String, Object?>{};
    final stateName = json['state']?.toString() ?? 'prepared';
    return OperationRecord(
      operationId: operationId,
      commandId: json['commandId']?.toString() ?? '',
      payloadHash: json['payloadHash']?.toString(),
      state: OperationState.values.firstWhere(
        (state) => state.name == stateName,
        orElse: () => OperationState.prepared,
      ),
      updatedAt: int.tryParse(json['updatedAt']?.toString() ?? '') ?? 0,
    );
  }

  OperationRecord copyWith({OperationState? state, int? updatedAt}) =>
      OperationRecord(
        operationId: operationId,
        commandId: commandId,
        payloadHash: payloadHash,
        state: state ?? this.state,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'operationId': operationId,
    'commandId': commandId,
    'payloadHash': payloadHash,
    'state': state.name,
    'updatedAt': updatedAt,
  };
}
