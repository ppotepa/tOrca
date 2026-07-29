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

  String get label => switch (this) {
    TransportPhase.connected => 'Połączono z relayem przez Tor',
    TransportPhase.starting => 'Uruchamianie Tor',
    TransportPhase.bootstrapping => 'Uruchamianie obwodu Tor',
    TransportPhase.connecting => 'Łączenie z relayem onion',
    TransportPhase.degraded => 'Relay działa w trybie ograniczonym',
    TransportPhase.reconnecting => 'Ponowne łączenie z relayem',
    TransportPhase.offline => 'Tor offline',
    TransportPhase.error => 'Sprawdzanie połączenia Tor',
  };
}

enum MobileTab { chats, contacts, inbox }

enum ConversationState { pending, verifying, active, failed, offline }

extension ConversationStateDisplay on ConversationState {
  String get wireValue => switch (this) {
    ConversationState.pending => EngineContract.conversationStatePending,
    ConversationState.verifying => EngineContract.conversationStateVerifying,
    ConversationState.active => EngineContract.conversationStateActive,
    ConversationState.failed => EngineContract.conversationStateFailed,
    ConversationState.offline => EngineContract.conversationStateOffline,
  };

  String get presenceLabel => switch (this) {
    ConversationState.active => 'online',
    ConversationState.offline => 'offline',
    ConversationState.failed => 'niedostępny',
    _ => 'łączenie',
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

  String get label => switch (this) {
    InviteState.pending => 'Oczekuje na decyzję',
    InviteState.accepted => 'Zaakceptowane, finalizacja kontaktu',
    InviteState.rejected => 'Odrzucone',
    InviteState.completed => 'Zakończone',
    InviteState.expired => 'Wygasło',
    InviteState.archived => 'Zarchiwizowane',
    InviteState.cancelled => 'Anulowane',
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
  failed;

  static MessageState fromValue(String? value) =>
      switch (value?.trim().toUpperCase()) {
        EngineContract.messageStateQueued => MessageState.queued,
        EngineContract.messageStateSending => MessageState.sending,
        EngineContract.messageStateSent => MessageState.sent,
        EngineContract.messageStateDelivered => MessageState.delivered,
        EngineContract.messageStateFailed => MessageState.failed,
        final state => throw FormatException('Unknown message state: $state'),
      };

  String get wireValue => switch (this) {
    MessageState.queued => EngineContract.messageStateQueued,
    MessageState.sending => EngineContract.messageStateSending,
    MessageState.sent => EngineContract.messageStateSent,
    MessageState.delivered => EngineContract.messageStateDelivered,
    MessageState.failed => EngineContract.messageStateFailed,
  };

  String get label => switch (this) {
    MessageState.queued => 'w kolejce',
    MessageState.sending => 'wysyłanie…',
    MessageState.sent => 'wysłano',
    MessageState.delivered => 'dostarczono',
    MessageState.failed => 'błąd wysyłania',
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
  });
  final String id;
  final String nickname;
  final String fingerprint;
  final String publicKey;
  final bool verified;
  final String? devFixture;

  factory ContactRecord.fromMap(Map<String, dynamic> map) => ContactRecord(
    id: _string(map, EngineContract.installationId),
    nickname: _string(map, EngineContract.nickname, defaultValue: 'Nieznany'),
    fingerprint: _string(map, EngineContract.fingerprint),
    publicKey: _string(map, EngineContract.publicKey),
    verified: _string(map, EngineContract.verification) == 'VERIFIED',
    devFixture: _optionalString(map, EngineContract.dev),
  );
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

  factory ConversationSummary.fromMap(
    Map<String, dynamic> map,
  ) => ConversationSummary(
    id: _string(map, EngineContract.id),
    contactId: _string(map, EngineContract.contactInstallationId),
    preview: _string(map, EngineContract.lastMessagePreview, defaultValue: 'Nowa rozmowa'),
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
  });
  final String id;
  final String text;
  final bool outgoing;
  final MessageState state;
  final String createdAt;

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: _string(map, EngineContract.id),
    text: _string(map, EngineContract.body),
    outgoing: map[EngineContract.outgoing] as bool? ?? false,
    state: _messageState(map[EngineContract.state]),
    createdAt: _timestamp(map[EngineContract.createdAt]),
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

class PairingItem {
  const PairingItem({
    required this.id,
    required this.status,
    this.availableActions = const [],
    this.peer,
    this.expiresAt = 0,
    this.received = true,
  });
  final String id;
  final InviteState status;
  final List<PairingAvailableAction> availableActions;
  final ContactRecord? peer;
  final int expiresAt;
  final bool received;

  factory PairingItem.fromMap(Map<String, dynamic> map) => PairingItem(
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
  );

  ContactRequest asContactRequest() => ContactRequest(
    id: id,
    peer: peer ?? ContactRecord.fromMap(const {}),
    status: status,
    availableActions: availableActions,
    expiresAt: expiresAt,
  );

  bool can(PairingAvailableAction action) => availableActions.contains(action);
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

extension ConversationListMetrics on Iterable<ConversationSummary> {
  int get totalUnread => fold<int>(0, (sum, item) => sum + item.unread);
}

extension InviteListMetrics on Iterable<PairingItem> {
  int get pendingCount =>
      where((item) => item.can(PairingAvailableAction.accept)).length;
}

sealed class RuntimeEvent {
  const RuntimeEvent();
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

class NotificationRequestedEvent extends RuntimeEvent {
  const NotificationRequestedEvent({
    required this.id,
    required this.title,
    required this.body,
    this.conversationId,
  });

  final String id;
  final String title;
  final String body;
  final String? conversationId;
}

Map<String, dynamic> _map(Map<String, dynamic> map, String key) =>
    Map<String, dynamic>.from(map[key] as Map);

List<Map<String, dynamic>> _listOfMaps(Object? value) =>
    (value as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
