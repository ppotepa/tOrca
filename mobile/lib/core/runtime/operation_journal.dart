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
  }) async {
    final key = stableId == null || stableId.isEmpty
        ? null
        : '$operation:$stableId';
    final values = _read();
    if (key != null && values[key]?.isNotEmpty == true) return values[key]!;
    final id =
        'operation-${DateTime.now().microsecondsSinceEpoch}-${values.length}';
    if (key != null) {
      while (values.length >= maxEntries) {
        values.remove(values.keys.first);
      }
      values[key] = id;
      await _preferences.setString(_key, jsonEncode(values));
    }
    return id;
  }

  Map<String, String> _read() {
    final raw = _preferences.getString(_key);
    if (raw == null) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } on FormatException {
      return <String, String>{};
    }
  }
}
