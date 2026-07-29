import 'dart:convert';

import 'runtime_response.dart';

sealed class RuntimeLine {
  const RuntimeLine();

  factory RuntimeLine.parse(String line) {
    try {
      final decoded = jsonDecode(line);
      return RuntimeLine.fromDynamic(decoded);
    } catch (error) {
      return RuntimeParseErrorLine(error);
    }
  }

  factory RuntimeLine.fromDynamic(Object? value) {
    final response = RuntimeResponse.fromDynamic(value);
    if (response.id != null) {
      return RuntimeResponseLine(response);
    }
    return RuntimeEventLine(response);
  }
}

final class RuntimeResponseLine extends RuntimeLine {
  const RuntimeResponseLine(this.response);

  final RuntimeResponse response;
}

final class RuntimeEventLine extends RuntimeLine {
  const RuntimeEventLine(this.response);

  final RuntimeResponse response;
}

final class RuntimeParseErrorLine extends RuntimeLine {
  const RuntimeParseErrorLine(this.error);

  final Object error;
}
