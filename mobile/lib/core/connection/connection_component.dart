enum ConnectionComponent {
  engine,
  localData,
  tor,
  relay,
  peerListener,
  onionService,
}

enum ConnectionComponentState { pending, starting, ready, degraded, failed }

class ConnectionComponentStatus {
  const ConnectionComponentStatus({
    required this.component,
    this.state = ConnectionComponentState.pending,
    this.detail = '',
    this.progress,
    this.attempt = 0,
    this.errorCode,
    this.generation = 0,
  });

  final ConnectionComponent component;
  final ConnectionComponentState state;
  final String detail;
  final int? progress;
  final int attempt;
  final String? errorCode;
  final int generation;

  bool get ready => state == ConnectionComponentState.ready;

  bool get usable =>
      state == ConnectionComponentState.ready ||
      state == ConnectionComponentState.degraded;

  bool get busy =>
      state == ConnectionComponentState.pending ||
      state == ConnectionComponentState.starting;

  ConnectionComponentStatus copyWith({
    ConnectionComponentState? state,
    String? detail,
    int? progress,
    bool clearProgress = false,
    int? attempt,
    String? errorCode,
    bool clearErrorCode = false,
    int? generation,
  }) => ConnectionComponentStatus(
    component: component,
    state: state ?? this.state,
    detail: detail ?? this.detail,
    progress: clearProgress ? null : progress ?? this.progress,
    attempt: attempt ?? this.attempt,
    errorCode: clearErrorCode ? null : errorCode ?? this.errorCode,
    generation: generation ?? this.generation,
  );
}

extension ConnectionComponentDisplay on ConnectionComponent {
  String get title => switch (this) {
    ConnectionComponent.engine => 'Silnik aplikacji',
    ConnectionComponent.localData => 'Dane lokalne',
    ConnectionComponent.tor => 'Sieć Tor',
    ConnectionComponent.relay => 'Relay TorChat',
    ConnectionComponent.peerListener => 'Lokalny listener P2P',
    ConnectionComponent.onionService => 'Onion tego urządzenia',
  };

  String get description => switch (this) {
    ConnectionComponent.engine => 'Wspólny silnik komunikatora',
    ConnectionComponent.localData => 'Tożsamość i zaszyfrowana baza lokalna',
    ConnectionComponent.tor => 'Proces Tor i lokalny endpoint SOCKS',
    ConnectionComponent.relay => 'Połączenie sterujące z relayem onion',
    ConnectionComponent.peerListener =>
      'Lokalny serwer przyjmujący połączenia peer',
    ConnectionComponent.onionService =>
      'Adres onion publikowany dla tego urządzenia',
  };
}
