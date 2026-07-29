import 'generated/runtime_contract.g.dart';

class RuntimeArguments {
  const RuntimeArguments._(this._value);

  const RuntimeArguments.emptyArgs() : _value = const <String, Object?>{};

  static const empty = RuntimeArguments.emptyArgs();

  final Map<String, Object?> _value;

  factory RuntimeArguments.nickname(String nickname) =>
      RuntimeArguments._({EngineContract.nickname: nickname});

  factory RuntimeArguments.code(String code) =>
      RuntimeArguments._({EngineContract.code: code});

  factory RuntimeArguments.pairingId(String pairingId) =>
      RuntimeArguments._({EngineContract.argPairingId: pairingId});

  factory RuntimeArguments.installationId(String installationId) =>
      RuntimeArguments._({EngineContract.argInstallationId: installationId});

  factory RuntimeArguments.id(String id) => RuntimeArguments._({EngineContract.argId: id});

  factory RuntimeArguments.message(String id, String text) =>
      RuntimeArguments._({EngineContract.argId: id, EngineContract.argText: text});

  factory RuntimeArguments.map(Map<String, Object?> value) =>
      RuntimeArguments._(Map<String, Object?>.from(value));

  factory RuntimeArguments.contactId(String contactId) =>
      RuntimeArguments._({EngineContract.argContactId: contactId});

  factory RuntimeArguments.fact(Map<String, Object?> fact) =>
      RuntimeArguments._({EngineContract.fact: Map<String, Object?>.from(fact)});

  Map<String, Object?> toMap() => Map<String, Object?>.from(_value);
}
