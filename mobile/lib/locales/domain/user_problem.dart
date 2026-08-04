import 'dart:convert';

import 'user_problem_code.dart';

final class UserProblem {
  const UserProblem({
    required this.code,
    this.arguments = const <String, Object?>{},
  });

  final UserProblemCode code;
  final Map<String, Object?> arguments;

  Map<String, Object?> toMap() => <String, Object?>{
    'errorCode': code.wireValue,
    'arguments': arguments,
  };

  String toJson() => jsonEncode(toMap());
}
