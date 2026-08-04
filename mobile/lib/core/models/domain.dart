import 'package:flutter/material.dart';

import '../runtime/runtime_contract.dart';

enum TransportPhase {
  starting,
  bootstrapping,
  connecting,
  degraded,
  connected,
  reconnecting,
  offline,
  error;

  static TransportPhase fromValue(String? value) => switch (value) {
    EngineContract.transportPhaseStarting => TransportPhase.starting,
    EngineContract.transportPhaseBootstrapping => TransportPhase.bootstrapping,
    EngineContract.transportPhaseConnecting => TransportPhase.connecting,
    EngineContract.transportPhaseDegraded => TransportPhase.degraded,
    EngineContract.transportPhaseConnected => TransportPhase.connected,
    EngineContract.transportPhaseReconnecting => TransportPhase.reconnecting,
    EngineContract.transportPhaseOffline => TransportPhase.offline,
    EngineContract.transportPhaseError => TransportPhase.error,
    final phase => throw FormatException('Unknown transport phase: $phase'),
  };

  bool get isConnected => this == TransportPhase.connected;

  bool get isWarning => this == TransportPhase.degraded;

  bool get isError =>
      this == TransportPhase.error || this == TransportPhase.offline;

  bool get isConnecting =>
      this == TransportPhase.starting ||
      this == TransportPhase.bootstrapping ||
      this == TransportPhase.connecting ||
      this == TransportPhase.reconnecting;
}

enum MobileTab { chats, contacts }

enum PeerServerStatus { starting, ready, offline, error }

class PeerEndpoint {
  const PeerEndpoint({
    required this.installationId,
    required this.onionAddress,
    required this.virtualPort,
    required this.sequence,
    required this.issuedAt,
    this.expiresAt,
    this.capabilities = const [],
  });

  final String installationId;
  final String onionAddress;
  final int virtualPort;
  final int sequence;
  final int issuedAt;
  final int? expiresAt;
  final List<String> capabilities;

  factory PeerEndpoint.fromMap(Map<String, dynamic> map) => PeerEndpoint(
    installationId: map[EngineContract.installationId]?.toString() ?? '',
    onionAddress: map[EngineContract.onionAddress]?.toString() ?? '',
    virtualPort: _intFrom(map[EngineContract.virtualPort]),
    sequence: _intFrom(map[EngineContract.sequence]),
    issuedAt: _intFrom(map[EngineContract.issuedAt]),
    expiresAt: map[EngineContract.expiresAt] == null
        ? null
        : _intFrom(map[EngineContract.expiresAt]),
    capabilities:
        (map[EngineContract.capabilities] as List<dynamic>? ?? const [])
            .map((value) => value.toString())
            .toList(growable: false),
  );
}

enum StartupStepKind {
  engine,
  localData,
  tor,
  peerListener,
  onionService,
  communication,
}

enum StartupStepState { pending, running, ready, warning, error, blocked }

class StartupStep {
  const StartupStep({
    required this.kind,
    this.state = StartupStepState.pending,
    this.detail = '',
  });

  final StartupStepKind kind;
  final StartupStepState state;
  final String detail;

  StartupStep copyWith({StartupStepState? state, String? detail}) =>
      StartupStep(
        kind: kind,
        state: state ?? this.state,
        detail: detail ?? this.detail,
      );
}

List<StartupStep> initialStartupSteps() => [
  for (final kind in StartupStepKind.values) StartupStep(kind: kind),
];

List<StartupStep> transitionStartupStep(
  List<StartupStep> current,
  StartupStepKind kind,
  StartupStepState nextState,
  String detail,
) {
  final steps = current.isEmpty ? initialStartupSteps() : current;
  final target = steps.indexWhere((step) => step.kind == kind);
  if (target < 0) return steps;
  final failed = steps.indexWhere(
    (step) => step.state == StartupStepState.error,
  );
  if (failed >= 0 && failed != target) return steps;
  if (steps[target].state == StartupStepState.ready &&
      nextState != StartupStepState.error) {
    return steps;
  }
  return [
    for (var index = 0; index < steps.length; index += 1)
      if (index == target)
        steps[index].copyWith(state: nextState, detail: detail)
      else if (nextState == StartupStepState.error && index > target)
        steps[index].copyWith(
          state: StartupStepState.blocked,
          detail: 'blocked_by_previous_error',
        )
      else if (nextState == StartupStepState.running && index > target)
        steps[index].copyWith(state: StartupStepState.pending, detail: '')
      else
        steps[index],
  ];
}

enum ConversationState { pending, verifying, active, failed, offline }

extension ConversationStateDisplay on ConversationState {
  String get wireValue => switch (this) {
    ConversationState.pending => EngineContract.conversationStatePending,
    ConversationState.verifying => EngineContract.conversationStateVerifying,
    ConversationState.active => EngineContract.conversationStateActive,
    ConversationState.failed => EngineContract.conversationStateFailed,
    ConversationState.offline => EngineContract.conversationStateOffline,
  };

  @Deprecated('Localize ConversationState in the presentation layer.')
  String get presenceLabel => switch (this) {
    ConversationState.active => 'online',
    ConversationState.offline => 'offline',
    ConversationState.failed => 'unavailable',
    _ => 'connecting',
  };

  bool get isOnline => this == ConversationState.active;

  bool get isOffline => this == ConversationState.offline;

  bool get isFailed => this == ConversationState.failed;
}

enum InviteState {
  pending,
  accepted,
  rejected,
  completed,
  expired,
  archived,
  cancelled;

  static InviteState fromValue(String? value) =>
      switch (value?.trim().toUpperCase()) {
        EngineContract.inviteStatePending => InviteState.pending,
        EngineContract.inviteStateAccepted => InviteState.accepted,
        EngineContract.inviteStateRejected => InviteState.rejected,
        EngineContract.inviteStateCompleted => InviteState.completed,
        EngineContract.inviteStateExpired => InviteState.expired,
        EngineContract.inviteStateArchived => InviteState.archived,
        EngineContract.inviteStateCancelled => InviteState.cancelled,
        final state => throw FormatException('Unknown invite state: $state'),
      };

  String get wireValue => switch (this) {
    InviteState.pending => EngineContract.inviteStatePending,
    InviteState.accepted => EngineContract.inviteStateAccepted,
    InviteState.rejected => EngineContract.inviteStateRejected,
    InviteState.completed => EngineContract.inviteStateCompleted,
    InviteState.expired => EngineContract.inviteStateExpired,
    InviteState.archived => EngineContract.inviteStateArchived,
    InviteState.cancelled => EngineContract.inviteStateCancelled,
  };

  IconData get outboxIcon => switch (this) {
    InviteState.completed => Icons.check_circle_outline,
    InviteState.rejected || InviteState.cancelled => Icons.block_outlined,
    InviteState.expired => Icons.timer_off_outlined,
    _ => Icons.schedule,
  };
}

enum PairingAvailableAction {
  accept,
  reject,
  archive,
  cancel;

  static PairingAvailableAction fromValue(String? value) =>
      switch (value?.trim().toUpperCase()) {
        EngineContract.pairingActionAccept => PairingAvailableAction.accept,
        EngineContract.pairingActionReject => PairingAvailableAction.reject,
        EngineContract.pairingActionArchive => PairingAvailableAction.archive,
        EngineContract.pairingActionCancel => PairingAvailableAction.cancel,
        final action => throw FormatException(
          'Unknown pairing available action: $action',
        ),
      };

  String get wireValue => switch (this) {
    PairingAvailableAction.accept => EngineContract.pairingActionAccept,
    PairingAvailableAction.reject => EngineContract.pairingActionReject,
    PairingAvailableAction.archive => EngineContract.pairingActionArchive,
    PairingAvailableAction.cancel => EngineContract.pairingActionCancel,
  };
}

enum MessageState {
  queued,
  sending,
  sent,
  delivered,
  read,
  failed;

  static MessageState fromValue(String? value) =>
      switch (value?.trim().toUpperCase()) {
        EngineContract.messageStateQueued => MessageState.queued,
        EngineContract.messageStateSending => MessageState.sending,
        EngineContract.messageStateSent => MessageState.sent,
        EngineContract.messageStateDelivered => MessageState.delivered,
        EngineContract.messageStateRead => MessageState.read,
        EngineContract.messageStateFailed => MessageState.failed,
        final state => throw FormatException('Unknown message state: $state'),
      };

  String get wireValue => switch (this) {
    MessageState.queued => EngineContract.messageStateQueued,
    MessageState.sending => EngineContract.messageStateSending,
    MessageState.sent => EngineContract.messageStateSent,
    MessageState.delivered => EngineContract.messageStateDelivered,
    MessageState.read => EngineContract.messageStateRead,
    MessageState.failed => EngineContract.messageStateFailed,
  };
}

class RuntimeTorStatus {
  const RuntimeTorStatus({
    this.phase = TransportPhase.starting,
    this.label = '',
    this.detail = '',
    this.progress,
    this.latencyMs,
    this.retryAttempt = 0,
  });
  final TransportPhase phase;
  final String label;
  final String detail;
  final int? progress;
  final int? latencyMs;
  final int retryAttempt;

  bool get connected => phase.isConnected;
  bool get warning => phase.isWarning;
  bool get failed => phase.isError;
  bool get usable => connected || warning;
  bool get busy => phase.isConnecting;

  RuntimeTorStatus copyWith({
    TransportPhase? phase,
    String? label,
    String? detail,
    int? progress,
    int? latencyMs,
    int? retryAttempt,
  }) => RuntimeTorStatus(
    phase: phase ?? this.phase,
    label: label ?? this.label,
    detail: detail ?? this.detail,
    progress: progress ?? this.progress,
    latencyMs: latencyMs ?? this.latencyMs,
    retryAttempt: retryAttempt ?? this.retryAttempt,
  );
}

enum TransportComponent {
  engine,
  peer;

  static TransportComponent fromValue(String? value) => switch (value) {
    'ENGINE' => engine,
    'PEER' => peer,
    _ => engine,
  };
}

enum TransportProbeState {
  idle,
  starting,
  ready,
  degraded,
  error,
  offline;

  static TransportProbeState fromValue(String? value) => switch (value) {
    'IDLE' => idle,
    'STARTING' => starting,
    'READY' => ready,
    'DEGRADED' => degraded,
    'OFFLINE' => offline,
    _ => error,
  };
}

class TransportStatusSnapshot {
  const TransportStatusSnapshot({
    required this.component,
    required this.state,
    required this.detail,
    this.progress,
    this.latencyMs,
    this.retryAttempt = 0,
    this.retryInMs,
    this.generation = 0,
    this.endpoint,
    this.updatedAt,
  });

  final TransportComponent component;
  final TransportProbeState state;
  final String detail;
  final int? progress;
  final int? latencyMs;
  final int retryAttempt;
  final int? retryInMs;
  final int generation;
  final String? endpoint;
  final int? updatedAt;
}

class StartupReadinessSnapshot {
  const StartupReadinessSnapshot({
    required this.engineReady,
    required this.localDataReady,
    required this.torReady,
    required this.peerListenerReady,
    required this.onionServiceReady,
    required this.generation,
    required this.detail,
  });

  factory StartupReadinessSnapshot.fromJson(Map<String, dynamic> json) =>
      StartupReadinessSnapshot(
        engineReady: json['engineReady'] == true,
        localDataReady: json['localDataReady'] == true,
        torReady: json['torReady'] == true,
        peerListenerReady: json['peerListenerReady'] == true,
        onionServiceReady: json['onionServiceReady'] == true,
        generation: (json['generation'] as num?)?.toInt() ?? 0,
        detail: json['detail']?.toString() ?? '',
      );

  final bool engineReady;
  final bool localDataReady;
  final bool torReady;
  final bool peerListenerReady;
  final bool onionServiceReady;
  final int generation;
  final String detail;
}

class RuntimeIdentity {
  const RuntimeIdentity({
    this.installationId = '',
    this.fingerprint = '',
    this.publicKey = '',
  });

  final String installationId;
  final String fingerprint;
  final String publicKey;

  factory RuntimeIdentity.fromMap(Map<String, dynamic> map) => RuntimeIdentity(
    installationId: _string(map, EngineContract.installationId),
    fingerprint: _string(map, EngineContract.fingerprint),
    publicKey: _string(map, EngineContract.publicKey),
  );

  RuntimeProfile toProfile([String nickname = '']) => RuntimeProfile(
    installationId: installationId,
    nickname: nickname,
    fingerprint: fingerprint,
    publicKey: publicKey,
  );
}

class RuntimeProfile {
  const RuntimeProfile({
    this.installationId = '',
    this.nickname = '',
    this.fingerprint = '',
    this.publicKey = '',
  });
  final String installationId;
  final String nickname;
  final String fingerprint;
  final String publicKey;

  factory RuntimeProfile.fromMap(Map<String, dynamic> map) => RuntimeProfile(
    installationId: _string(map, EngineContract.installationId),
    nickname: _string(map, EngineContract.nickname),
    fingerprint: _string(map, EngineContract.fingerprint),
    publicKey: _string(map, EngineContract.publicKey),
  );
}

class ContactRecord {
  const ContactRecord({
    required this.id,
    required this.nickname,
    required this.fingerprint,
    required this.publicKey,
    required this.verified,
    this.devFixture,
    this.localAlias,
    this.muted = false,
    this.blocked = false,
    this.peerEndpointStatus = PeerEndpointStatus.missing,
    this.peerConnectionStatus = PeerConnectionStatus.offline,
    this.lastPeerConnectedAt,
    this.lastSeenAt,
    this.transportPolicy = ContactTransportPolicy.peerOnly,
  });
  final String id;
  final String nickname;
  final String fingerprint;
  final String publicKey;
  final bool verified;
  final String? devFixture;
  final String? localAlias;
  final bool muted;
  final bool blocked;
  final PeerEndpointStatus peerEndpointStatus;
  final PeerConnectionStatus peerConnectionStatus;
  final String? lastPeerConnectedAt;
  final String? lastSeenAt;
  final ContactTransportPolicy transportPolicy;

  String get displayName {
    final alias = localAlias?.trim() ?? '';
    if (alias.isNotEmpty) return alias;
    final name = nickname.trim();
    return name.isNotEmpty ? name : id;
  }

  factory ContactRecord.fromMap(Map<String, dynamic> map) => ContactRecord(
    id: _string(map, EngineContract.installationId),
    nickname: _string(map, EngineContract.nickname),
    fingerprint: _string(map, EngineContract.fingerprint),
    publicKey: _string(map, EngineContract.publicKey),
    verified: _string(map, EngineContract.verification) == 'VERIFIED',
    devFixture: _optionalString(map, EngineContract.dev),
    localAlias: _optionalString(map, EngineContract.localAlias),
    muted: map[EngineContract.muted] as bool? ?? false,
    blocked: map[EngineContract.blocked] as bool? ?? false,
    peerEndpointStatus: PeerEndpointStatus.fromValue(
      map[EngineContract.peerEndpointStatus]?.toString(),
    ),
    peerConnectionStatus: PeerConnectionStatus.fromValue(
      map[EngineContract.peerConnectionStatus]?.toString(),
    ),
    lastPeerConnectedAt: _optionalString(
      map,
      EngineContract.lastPeerConnectedAt,
    ),
    lastSeenAt: _optionalString(map, EngineContract.lastSeenAt),
    transportPolicy: ContactTransportPolicy.fromValue(
      map[EngineContract.transportPolicy]?.toString(),
    ),
  );

  ContactRecord copyWith({
    String? id,
    String? nickname,
    String? fingerprint,
    String? publicKey,
    bool? verified,
    Object? devFixture = _contactRecordSentinel,
    Object? localAlias = _contactRecordSentinel,
    bool? muted,
    bool? blocked,
    PeerEndpointStatus? peerEndpointStatus,
    PeerConnectionStatus? peerConnectionStatus,
    Object? lastPeerConnectedAt = _contactRecordSentinel,
    Object? lastSeenAt = _contactRecordSentinel,
    ContactTransportPolicy? transportPolicy,
  }) => ContactRecord(
    id: id ?? this.id,
    nickname: nickname ?? this.nickname,
    fingerprint: fingerprint ?? this.fingerprint,
    publicKey: publicKey ?? this.publicKey,
    verified: verified ?? this.verified,
    devFixture: identical(devFixture, _contactRecordSentinel)
        ? this.devFixture
        : devFixture as String?,
    localAlias: identical(localAlias, _contactRecordSentinel)
        ? this.localAlias
        : localAlias as String?,
    muted: muted ?? this.muted,
    blocked: blocked ?? this.blocked,
    peerEndpointStatus: peerEndpointStatus ?? this.peerEndpointStatus,
    peerConnectionStatus: peerConnectionStatus ?? this.peerConnectionStatus,
    lastPeerConnectedAt: identical(lastPeerConnectedAt, _contactRecordSentinel)
        ? this.lastPeerConnectedAt
        : lastPeerConnectedAt as String?,
    lastSeenAt: identical(lastSeenAt, _contactRecordSentinel)
        ? this.lastSeenAt
        : lastSeenAt as String?,
    transportPolicy: transportPolicy ?? this.transportPolicy,
  );
}

const Object _contactRecordSentinel = Object();

int _intFrom(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

enum ContactTransportPolicy {
  peerOnly;

  factory ContactTransportPolicy.fromValue(String? value) => peerOnly;

  String get wireValue => EngineContract.contactTransportPolicyPeerOnly;
}

enum PeerEndpointStatus {
  missing,
  pendingExchange,
  verified,
  invalid;

  factory PeerEndpointStatus.fromValue(String? value) => switch (value) {
    EngineContract.peerEndpointStatusPendingExchange => pendingExchange,
    EngineContract.peerEndpointStatusVerified => verified,
    EngineContract.peerEndpointStatusInvalid => invalid,
    _ => missing,
  };
}

enum CapabilityStatus {
  missing,
  pending,
  active,
  rotating,
  revoked,
  expired;

  static CapabilityStatus fromValue(String? value) => switch (value) {
    'MISSING' => missing,
    'PENDING' => pending,
    'ROTATING' => rotating,
    'REVOKED' => revoked,
    'EXPIRED' => expired,
    _ => active,
  };
}

class ContactEndpointCapabilityStatus {
  const ContactEndpointCapabilityStatus({
    required this.contactId,
    required this.capabilityId,
    required this.sequence,
    required this.status,
  });

  final String contactId;
  final String capabilityId;
  final int sequence;
  final CapabilityStatus status;

  factory ContactEndpointCapabilityStatus.fromMap(Map<String, dynamic> map) =>
      ContactEndpointCapabilityStatus(
        contactId: map['contactId']?.toString() ?? '',
        capabilityId: map['capabilityId']?.toString() ?? '',
        sequence: (map['sequence'] as num?)?.toInt() ?? 0,
        status: CapabilityStatus.fromValue(map['status']?.toString()),
      );
}

enum PeerConnectionStatus {
  offline,
  connecting,
  authenticating,
  connected,
  backoff;

  factory PeerConnectionStatus.fromValue(String? value) => switch (value) {
    EngineContract.peerConnectionStatusConnecting => connecting,
    EngineContract.peerConnectionStatusAuthenticating => authenticating,
    EngineContract.peerConnectionStatusConnected => connected,
    EngineContract.peerConnectionStatusBackoff => backoff,
    _ => offline,
  };
}

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.contactId,
    required this.preview,
    required this.unread,
    this.state = ConversationState.pending,
    this.lastMessageAt = '',
  });
  final String id;
  final String contactId;
  final String preview;
  final int unread;
  final ConversationState state;
  final String lastMessageAt;

  factory ConversationSummary.fromMap(Map<String, dynamic> map) =>
      ConversationSummary(
        id: _string(map, EngineContract.id),
        contactId: _string(map, EngineContract.contactInstallationId),
        preview: _string(map, EngineContract.lastMessagePreview),
        unread: _int(map, EngineContract.unreadCount),
        state: _conversationState(_optionalString(map, EngineContract.status)),
        lastMessageAt: _timestamp(map[EngineContract.lastMessageAt]),
      );
}

ConversationState _conversationState(String? value) => switch (value
    ?.trim()
    .toUpperCase()) {
  EngineContract.conversationStateActive => ConversationState.active,
  EngineContract.conversationStatePending => ConversationState.pending,
  EngineContract.conversationStateVerifying => ConversationState.verifying,
  EngineContract.conversationStateFailed => ConversationState.failed,
  EngineContract.conversationStateOffline => ConversationState.offline,
  final state => throw FormatException('Unknown conversation state: $state'),
};

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.text,
    required this.outgoing,
    required this.state,
    this.createdAt = '',
    this.replyTo,
  });
  final String id;
  final String text;
  final bool outgoing;
  final MessageState state;
  final String createdAt;
  final MessageReply? replyTo;

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: _string(map, EngineContract.id),
    text: _string(map, EngineContract.body),
    outgoing: map[EngineContract.outgoing] as bool? ?? false,
    state: _messageState(map[EngineContract.state]),
    createdAt: _timestamp(map[EngineContract.createdAt]),
    replyTo: map[EngineContract.replyTo] is Map
        ? MessageReply.fromMap(
            Map<String, dynamic>.from(map[EngineContract.replyTo] as Map),
          )
        : null,
  );
}

class MessageReply {
  const MessageReply({
    required this.messageId,
    required this.text,
    required this.outgoing,
  });

  final String messageId;
  final String text;
  final bool outgoing;

  factory MessageReply.fromMap(Map<String, dynamic> map) => MessageReply(
    messageId: _string(map, EngineContract.messageId),
    text: _string(map, EngineContract.body),
    outgoing: map[EngineContract.outgoing] as bool? ?? false,
  );
}

MessageState _messageState(Object? value) {
  if (value is MessageState) return value;
  return MessageState.fromValue(value?.toString());
}

String _timestamp(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt()).toIso8601String();
  }
  final text = value?.toString() ?? '';
  final epoch = int.tryParse(text);
  return epoch == null
      ? text
      : DateTime.fromMillisecondsSinceEpoch(epoch).toIso8601String();
}

String _string(
  Map<String, dynamic> map,
  String key, {
  String defaultValue = '',
}) => _optionalString(map, key) ?? defaultValue;

String? _optionalString(Map<String, dynamic> map, String key) {
  final value = map[key];
  return value?.toString();
}

int _int(Map<String, dynamic> map, String key) {
  final value = map[key];
  return (value as num?)?.toInt() ?? int.tryParse(value?.toString() ?? '') ?? 0;
}

enum PairingOrigin { inbox, outbox, unknown }

class PairingItem {
  const PairingItem({
    required this.id,
    required this.status,
    this.availableActions = const [],
    this.peer,
    this.expiresAt = 0,
    this.received = true,
    this.origin = PairingOrigin.unknown,
  });
  final String id;
  final InviteState status;
  final List<PairingAvailableAction> availableActions;
  final ContactRecord? peer;
  final int expiresAt;
  final bool received;
  final PairingOrigin origin;

  factory PairingItem.fromMap(
    Map<String, dynamic> map, {
    PairingOrigin origin = PairingOrigin.unknown,
  }) => PairingItem(
    id: _string(map, EngineContract.pairingId),
    status: InviteState.fromValue(_string(map, EngineContract.state)),
    availableActions: _availableActions(map),
    peer: map[EngineContract.sender] is Map
        ? ContactRecord.fromMap(
            Map<String, dynamic>.from(map[EngineContract.sender] as Map),
          )
        : null,
    expiresAt: _int(map, EngineContract.expiresAt),
    received: map[EngineContract.received] as bool? ?? false,
    origin: origin,
  );

  ContactRequest asContactRequest() => ContactRequest(
    id: id,
    peer: peer ?? ContactRecord.fromMap(const {}),
    status: status,
    availableActions: availableActions,
    expiresAt: expiresAt,
  );

  bool can(PairingAvailableAction action) => availableActions.contains(action);

  bool get requiresLocalDecision =>
      origin == PairingOrigin.inbox &&
      status == InviteState.pending &&
      can(PairingAvailableAction.accept);
}

class ContactRequest {
  const ContactRequest({
    required this.id,
    required this.peer,
    required this.status,
    this.availableActions = const [],
    this.expiresAt = 0,
  });
  final String id;
  final ContactRecord peer;
  final InviteState status;
  final List<PairingAvailableAction> availableActions;
  final int expiresAt;

  bool can(PairingAvailableAction action) => availableActions.contains(action);
}

class InviteCode {
  const InviteCode({required this.code, this.expiresAt = 0});
  final String code;
  final int expiresAt;

  factory InviteCode.fromMap(Map<String, dynamic> map) => InviteCode(
    code: _string(map, EngineContract.code),
    expiresAt: _int(map, EngineContract.expiresAt),
  );
}

extension IterableFirstOrNull<T> on Iterable<T> {
  T? firstOrNullWhere(bool Function(T element) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}

List<PairingAvailableAction> _availableActions(Map<String, dynamic> map) {
  final value = map[EngineContract.availableActions];
  if (value == null) return const [];
  if (value is! List) {
    throw const FormatException('availableActions must be a list');
  }
  return value
      .map((item) => PairingAvailableAction.fromValue(item?.toString()))
      .toList(growable: false);
}

class RuntimeFixture {
  const RuntimeFixture({
    required this.identity,
    required this.profile,
    required this.contact,
    required this.conversation,
    required this.message,
    required this.pairingCode,
    required this.pairingInboxItem,
    required this.pairingOutboxItem,
    required this.events,
  });

  final RuntimeIdentity identity;
  final RuntimeProfile profile;
  final ContactRecord contact;
  final ConversationSummary conversation;
  final ChatMessage message;
  final InviteCode pairingCode;
  final PairingItem pairingInboxItem;
  final PairingItem pairingOutboxItem;
  final List<Map<String, dynamic>> events;

  factory RuntimeFixture.fromMap(Map<String, dynamic> map) => RuntimeFixture(
    identity: RuntimeIdentity.fromMap(_map(map, 'identity')),
    profile: RuntimeProfile.fromMap(_map(map, 'profile')),
    contact: ContactRecord.fromMap(_map(map, 'contact')),
    conversation: ConversationSummary.fromMap(_map(map, 'conversation')),
    message: ChatMessage.fromMap(_map(map, 'message')),
    pairingCode: InviteCode.fromMap(_map(map, 'pairingCode')),
    pairingInboxItem: PairingItem.fromMap(_map(map, 'pairingInboxItem')),
    pairingOutboxItem: PairingItem.fromMap(_map(map, 'pairingOutboxItem')),
    events: _listOfMaps(map['events']),
  );
}

extension InviteListMetrics on Iterable<PairingItem> {
  int get pendingCount =>
      where((item) => item.can(PairingAvailableAction.accept)).length;
}

sealed class RuntimeEvent {
  const RuntimeEvent();
}

class TransportStatusChangedEvent extends RuntimeEvent {
  const TransportStatusChangedEvent(this.snapshot);

  final TransportStatusSnapshot snapshot;
}

class TorStatusEvent extends RuntimeEvent {
  const TorStatusEvent(this.snapshot);
  final RuntimeTorStatus snapshot;
}

class RuntimeReadyEvent extends RuntimeEvent {
  const RuntimeReadyEvent(this.protocol);
  final int protocol;
}

class ProfileReadyEvent extends RuntimeEvent {
  const ProfileReadyEvent(this.profile);
  final RuntimeProfile profile;
}

class PeerEndpointChangedEvent extends RuntimeEvent {
  const PeerEndpointChangedEvent({
    required this.contactId,
    required this.status,
  });

  final String contactId;
  final PeerEndpointStatus status;
}

class PeerConnectionChangedEvent extends RuntimeEvent {
  const PeerConnectionChangedEvent({
    required this.contactId,
    required this.status,
    this.retryInMs,
  });

  final String contactId;
  final PeerConnectionStatus status;
  final int? retryInMs;
}

class ContactCapabilityChangedEvent extends RuntimeEvent {
  const ContactCapabilityChangedEvent({
    required this.contactId,
    required this.capabilityId,
    required this.sequence,
    required this.status,
  });

  final String contactId;
  final String capabilityId;
  final int sequence;
  final CapabilityStatus status;
}

class DataChangedEvent extends RuntimeEvent {
  const DataChangedEvent(this.type, [this.payload = const <String, dynamic>{}]);
  final String type;
  final Map<String, dynamic> payload;
}

class RuntimeErrorEvent extends RuntimeEvent {
  const RuntimeErrorEvent(this.message);
  final String message;
}

class RuntimeLogEvent extends RuntimeEvent {
  const RuntimeLogEvent(this.message);
  final String message;
}

enum NotificationKind {
  messageReceived('message_received'),
  pairingRequest('pairing_request'),
  pairingCompleted('pairing_completed');

  const NotificationKind(this.wireValue);
  final String wireValue;

  static NotificationKind fromWire(Object? value) =>
      NotificationKind.values.firstWhere(
        (item) => item.wireValue == value,
        orElse: () => NotificationKind.messageReceived,
      );
}

class NotificationRequestedEvent extends RuntimeEvent {
  const NotificationRequestedEvent({
    required this.id,
    required this.kind,
    this.conversationId,
    this.previewText,
  });

  final String id;
  final NotificationKind kind;
  final String? conversationId;
  final String? previewText;
}

Map<String, dynamic> _map(Map<String, dynamic> map, String key) =>
    Map<String, dynamic>.from(map[key] as Map);

List<Map<String, dynamic>> _listOfMaps(Object? value) =>
    (value as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
