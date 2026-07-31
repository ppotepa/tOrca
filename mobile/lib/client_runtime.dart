import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'core/application_state/application_snapshot.dart';
import 'core/application_state/application_state_store.dart';
import 'windows_runtime.dart';
export 'core/models/domain.dart';
import 'core/models/domain.dart';

const _sessionNicknameKey = 'torchat.session.nickname';

/// Optional capability for platforms whose native process outlives Flutter UI.
abstract interface class RuntimeAttachmentProvider {
  Future<Map<String, dynamic>?> runtimeSnapshot();
}

/// Platform-neutral contract consumed by the Flutter UI.
abstract interface class ClientRuntime {
  Stream<RuntimeEvent> get events;
  Future<bool> connect();
  Future<RuntimeIdentity?> identity();
  Future<RuntimeProfile?> profile();
  Future<InviteCode?> refreshPairingCode();
  Future<RuntimeProfile> setNickname(String nickname);
  Future<PairingItem> submitPairingCode(String code);
  Future<List<PairingItem>> pairingInbox();
  Future<List<PairingItem>> pairingOutbox();
  Future<PeerEndpoint?> peerEndpoint();
  Future<bool> peerEndpointAvailable();
  Future<void> retryPeerConnection(String installationId);
  Future<void> rotatePeerEndpoint();
  Future<void> verifyContact(String installationId);
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  });
  Future<List<ContactRecord>> contacts();
  Future<List<ConversationSummary>> conversations();
  Future<List<ChatMessage>> messages(String id);
  Future<void> openConversation(String id);
  Future<void> closeConversation();
  Future<void> startConversation(String contactId);
  Future<void> sendMessage(String id, String text, {String? replyToMessageId});
  Future<void> retryMessage(String messageId) async {}
  Future<void> deleteMessageLocal(String messageId) async {}
  Future<void> setTyping(String conversationId, bool typing) async {}
  Future<void> setPresence(bool online) async {}
  Future<void> sendReadReceipts(String conversationId) async {}
  Future<void> acceptPairing(String pairingId);
  Future<void> rejectPairing(String pairingId);
  Future<void> cancelPairing(String pairingId);
  Future<void> archivePairing(String pairingId);
  Future<void> updateAppVisibility(bool foreground);
}

final class _SessionAwareClientRuntime
    implements ClientRuntime, RuntimeAttachmentProvider {
  _SessionAwareClientRuntime(this._delegate);

  final ClientRuntime _delegate;

  Future<void> _checkpoint(RuntimeProfile? profile) async {
    final nickname = profile?.nickname.trim() ?? '';
    if (nickname.length < 2) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_sessionNicknameKey, nickname);
  }

  @override
  Future<Map<String, dynamic>?> runtimeSnapshot() async {
    Map<String, dynamic>? snapshot;
    if (_delegate case final RuntimeAttachmentProvider provider) {
      snapshot = await provider.runtimeSnapshot();
    }
    snapshot ??= await _composeSnapshotFromDelegate();
    if (snapshot != null) {
      await _hydrateSnapshot(snapshot);
      return snapshot;
    }

    final preferences = await SharedPreferences.getInstance();
    final nickname = preferences.getString(_sessionNicknameKey)?.trim() ?? '';
    if (nickname.length < 2) return null;
    return <String, dynamic>{
      'serviceAlive': false,
      'localDataReady': false,
      'checkpointOnly': true,
      'profile': <String, dynamic>{'nickname': nickname},
    };
  }

  Future<Map<String, dynamic>?> _composeSnapshotFromDelegate() async {
    try {
      final values = await Future.wait<Object?>([
        _delegate.identity(),
        _delegate.profile(),
        _delegate.contacts(),
        _delegate.conversations(),
        _delegate.peerEndpointAvailable(),
      ]);
      final identity = values[0] as RuntimeIdentity?;
      final profile = values[1] as RuntimeProfile?;
      if (identity == null || profile == null) return null;
      final contacts = values[2] as List<ContactRecord>;
      final conversations = values[3] as List<ConversationSummary>;
      return <String, dynamic>{
        'serviceAlive': true,
        'localDataReady': true,
        'generation': DateTime.now().microsecondsSinceEpoch,
        'createdAtMs': DateTime.now().millisecondsSinceEpoch,
        'identity': _identityMap(identity),
        'profile': _profileMap(profile),
        'contacts': contacts.map(_contactMap).toList(growable: false),
        'conversations': conversations
            .map(_conversationMap)
            .toList(growable: false),
        'peerEndpointAvailable': values[4] as bool,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _hydrateSnapshot(Map<String, dynamic> raw) async {
    final identityMap = _map(raw['identity']);
    final profileMap = _map(raw['profile']);
    if (identityMap == null || profileMap == null) return;

    final identity = RuntimeIdentity.fromMap(identityMap);
    final profile = RuntimeProfile.fromMap(profileMap);
    final contacts = _mapList(raw['contacts'])
        .map(ContactRecord.fromMap)
        .toList(growable: false);
    final conversations = _mapList(raw['conversations'])
        .map(ConversationSummary.fromMap)
        .toList(growable: false);
    final generation = _intValue(raw['generation']) == 0
        ? DateTime.now().microsecondsSinceEpoch
        : _intValue(raw['generation']);

    final current = ApplicationStateStore.shared.current;
    if (current != null &&
        current.identity.installationId.isNotEmpty &&
        identity.installationId.isNotEmpty &&
        current.identity.installationId != identity.installationId) {
      ApplicationStateStore.shared.clear();
    }
    ApplicationStateStore.shared.hydrate(
      ApplicationSnapshot(
        generation: generation,
        createdAtMs: _intValue(raw['createdAtMs']),
        identity: identity,
        profile: profile,
        contacts: List.unmodifiable(contacts),
        conversations: List.unmodifiable(conversations),
        pendingInbox: _intValue(raw['pendingInbox']),
        pendingOutbox: _intValue(raw['pendingOutbox']),
        peerEndpointAvailable: raw['peerEndpointAvailable'] == true,
      ),
    );
    await _checkpoint(profile);
  }

  @override
  Stream<RuntimeEvent> get events => _delegate.events;
  @override
  Future<bool> connect() => _delegate.connect();
  @override
  Future<RuntimeIdentity?> identity() => _delegate.identity();
  @override
  Future<RuntimeProfile?> profile() async {
    final value = await _delegate.profile();
    await _checkpoint(value);
    return value;
  }
  @override
  Future<InviteCode?> refreshPairingCode() => _delegate.refreshPairingCode();
  @override
  Future<RuntimeProfile> setNickname(String nickname) async {
    final value = await _delegate.setNickname(nickname);
    await _checkpoint(value);
    return value;
  }
  @override
  Future<PairingItem> submitPairingCode(String code) =>
      _delegate.submitPairingCode(code);
  @override
  Future<List<PairingItem>> pairingInbox() => _delegate.pairingInbox();
  @override
  Future<List<PairingItem>> pairingOutbox() => _delegate.pairingOutbox();
  @override
  Future<PeerEndpoint?> peerEndpoint() => _delegate.peerEndpoint();
  @override
  Future<bool> peerEndpointAvailable() => _delegate.peerEndpointAvailable();
  @override
  Future<void> retryPeerConnection(String installationId) =>
      _delegate.retryPeerConnection(installationId);
  @override
  Future<void> rotatePeerEndpoint() => _delegate.rotatePeerEndpoint();
  @override
  Future<void> verifyContact(String installationId) =>
      _delegate.verifyContact(installationId);
  @override
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) => _delegate.updateContactSettings(
    installationId,
    localAlias: localAlias,
    muted: muted,
    blocked: blocked,
    transportPolicy: transportPolicy,
  );
  @override
  Future<List<ContactRecord>> contacts() => _delegate.contacts();
  @override
  Future<List<ConversationSummary>> conversations() =>
      _delegate.conversations();
  @override
  Future<List<ChatMessage>> messages(String id) => _delegate.messages(id);
  @override
  Future<void> openConversation(String id) => _delegate.openConversation(id);
  @override
  Future<void> closeConversation() => _delegate.closeConversation();
  @override
  Future<void> startConversation(String contactId) =>
      _delegate.startConversation(contactId);
  @override
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) => _delegate.sendMessage(id, text, replyToMessageId: replyToMessageId);
  @override
  Future<void> retryMessage(String messageId) =>
      _delegate.retryMessage(messageId);
  @override
  Future<void> deleteMessageLocal(String messageId) =>
      _delegate.deleteMessageLocal(messageId);
  @override
  Future<void> setTyping(String conversationId, bool typing) =>
      _delegate.setTyping(conversationId, typing);
  @override
  Future<void> setPresence(bool online) => _delegate.setPresence(online);
  @override
  Future<void> sendReadReceipts(String conversationId) =>
      _delegate.sendReadReceipts(conversationId);
  @override
  Future<void> acceptPairing(String pairingId) =>
      _delegate.acceptPairing(pairingId);
  @override
  Future<void> rejectPairing(String pairingId) =>
      _delegate.rejectPairing(pairingId);
  @override
  Future<void> cancelPairing(String pairingId) =>
      _delegate.cancelPairing(pairingId);
  @override
  Future<void> archivePairing(String pairingId) =>
      _delegate.archivePairing(pairingId);
  @override
  Future<void> updateAppVisibility(bool foreground) =>
      _delegate.updateAppVisibility(foreground);
}

/// Keeps process-backed desktop calls on one ordered command stream.
final class _SerializedClientRuntime implements ClientRuntime {
  _SerializedClientRuntime(this._delegate);

  final ClientRuntime _delegate;
  Future<void> _tail = Future<void>.value();

  Future<T> _run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.catchError((Object _) {}).then<void>((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  Stream<RuntimeEvent> get events => _delegate.events;
  @override
  Future<bool> connect() => _run(_delegate.connect);
  @override
  Future<RuntimeIdentity?> identity() => _run(_delegate.identity);
  @override
  Future<RuntimeProfile?> profile() => _run(_delegate.profile);
  @override
  Future<InviteCode?> refreshPairingCode() => _run(_delegate.refreshPairingCode);
  @override
  Future<RuntimeProfile> setNickname(String nickname) =>
      _run(() => _delegate.setNickname(nickname));
  @override
  Future<PairingItem> submitPairingCode(String code) =>
      _run(() => _delegate.submitPairingCode(code));
  @override
  Future<List<PairingItem>> pairingInbox() => _run(_delegate.pairingInbox);
  @override
  Future<List<PairingItem>> pairingOutbox() => _run(_delegate.pairingOutbox);
  @override
  Future<PeerEndpoint?> peerEndpoint() => _run(_delegate.peerEndpoint);
  @override
  Future<bool> peerEndpointAvailable() => _run(_delegate.peerEndpointAvailable);
  @override
  Future<void> retryPeerConnection(String installationId) =>
      _run(() => _delegate.retryPeerConnection(installationId));
  @override
  Future<void> rotatePeerEndpoint() => _run(_delegate.rotatePeerEndpoint);
  @override
  Future<void> verifyContact(String installationId) =>
      _run(() => _delegate.verifyContact(installationId));
  @override
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) => _run(
    () => _delegate.updateContactSettings(
      installationId,
      localAlias: localAlias,
      muted: muted,
      blocked: blocked,
      transportPolicy: transportPolicy,
    ),
  );
  @override
  Future<List<ContactRecord>> contacts() => _run(_delegate.contacts);
  @override
  Future<List<ConversationSummary>> conversations() =>
      _run(_delegate.conversations);
  @override
  Future<List<ChatMessage>> messages(String id) =>
      _run(() => _delegate.messages(id));
  @override
  Future<void> openConversation(String id) =>
      _run(() => _delegate.openConversation(id));
  @override
  Future<void> closeConversation() => _run(_delegate.closeConversation);
  @override
  Future<void> startConversation(String contactId) =>
      _run(() => _delegate.startConversation(contactId));
  @override
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) => _run(
    () => _delegate.sendMessage(
      id,
      text,
      replyToMessageId: replyToMessageId,
    ),
  );
  @override
  Future<void> retryMessage(String messageId) =>
      _run(() => _delegate.retryMessage(messageId));
  @override
  Future<void> deleteMessageLocal(String messageId) =>
      _run(() => _delegate.deleteMessageLocal(messageId));
  @override
  Future<void> setTyping(String conversationId, bool typing) =>
      _run(() => _delegate.setTyping(conversationId, typing));
  @override
  Future<void> setPresence(bool online) =>
      _run(() => _delegate.setPresence(online));
  @override
  Future<void> sendReadReceipts(String conversationId) =>
      _run(() => _delegate.sendReadReceipts(conversationId));
  @override
  Future<void> acceptPairing(String pairingId) =>
      _run(() => _delegate.acceptPairing(pairingId));
  @override
  Future<void> rejectPairing(String pairingId) =>
      _run(() => _delegate.rejectPairing(pairingId));
  @override
  Future<void> cancelPairing(String pairingId) =>
      _run(() => _delegate.cancelPairing(pairingId));
  @override
  Future<void> archivePairing(String pairingId) =>
      _run(() => _delegate.archivePairing(pairingId));
  @override
  Future<void> updateAppVisibility(bool foreground) =>
      _run(() => _delegate.updateAppVisibility(foreground));
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

List<Map<String, dynamic>> _mapList(Object? value) =>
    (value as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

Map<String, dynamic> _identityMap(RuntimeIdentity value) => {
  'installationId': value.installationId,
  'publicKey': value.publicKey,
  'fingerprint': value.fingerprint,
};

Map<String, dynamic> _profileMap(RuntimeProfile value) => {
  'installationId': value.installationId,
  'nickname': value.nickname,
  'publicKey': value.publicKey,
  'fingerprint': value.fingerprint,
};

Map<String, dynamic> _contactMap(ContactRecord value) => {
  'installationId': value.id,
  'nickname': value.nickname,
  'publicKey': value.publicKey,
  'fingerprint': value.fingerprint,
  'localAlias': value.localAlias,
  'muted': value.muted,
  'blocked': value.blocked,
  'verification': value.verified ? 'VERIFIED' : 'UNVERIFIED',
  'peerEndpointStatus': value.peerEndpointStatus.name
      .replaceAllMapped(RegExp(r'([A-Z])'), (match) => '_${match[1]}')
      .toUpperCase(),
  'peerConnectionStatus': value.peerConnectionStatus.name.toUpperCase(),
  'lastPeerConnectedAt': value.lastPeerConnectedAt,
  'transportPolicy': value.transportPolicy.wireValue,
};

Map<String, dynamic> _conversationMap(ConversationSummary value) => {
  'id': value.id,
  'contactInstallationId': value.contactId,
  'status': value.state.wireValue,
  'lastMessagePreview': value.preview,
  'lastMessageAt': value.lastMessageAt,
  'unreadCount': value.unread,
};

ClientRuntime createClientRuntime() {
  final platform = createPlatformRuntime();
  final ordered = Platform.isWindows || Platform.isLinux || Platform.isMacOS
      ? _SerializedClientRuntime(platform)
      : platform;
  return _SessionAwareClientRuntime(ordered);
}
