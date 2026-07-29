class RuntimeArguments {
  const RuntimeArguments._(this._value);

  const RuntimeArguments.emptyArgs() : _value = const <String, Object?>{};

  static const empty = RuntimeArguments.emptyArgs();

  final Map<String, Object?> _value;

  factory RuntimeArguments.nickname(String nickname) =>
      RuntimeArguments._({'nickname': nickname});

  factory RuntimeArguments.code(String code) =>
      RuntimeArguments._({'code': code});

  factory RuntimeArguments.pairingId(String pairingId) =>
      RuntimeArguments._({'pairingId': pairingId});

  factory RuntimeArguments.installationId(String installationId) =>
      RuntimeArguments._({'installationId': installationId});

  factory RuntimeArguments.id(String id) => RuntimeArguments._({'id': id});

  factory RuntimeArguments.message(String id, String text) =>
      RuntimeArguments._({'id': id, 'text': text});

  factory RuntimeArguments.map(Map<String, Object?> value) =>
      RuntimeArguments._(Map<String, Object?>.from(value));

  factory RuntimeArguments.contactId(String contactId) =>
      RuntimeArguments._({'contactId': contactId});

  Map<String, Object?> toMap() => Map<String, Object?>.from(_value);
}
