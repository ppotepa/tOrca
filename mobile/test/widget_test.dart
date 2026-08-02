import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/client_runtime.dart';
import 'package:torchat_mobile/core/application_state/application_snapshot_codec.dart';
import 'package:torchat_mobile/core/application_state/application_state_store.dart';
import 'package:torchat_mobile/main.dart';

class _SplashRuntime implements ClientRuntime {
  const _SplashRuntime();

  @override
  Stream<RuntimeEvent> get events => const Stream.empty();
  @override
  Future<bool> connect() async => true;
  @override
  Future<StartupReadinessSnapshot> startupReadiness() async =>
      const StartupReadinessSnapshot(
        engineReady: true,
        localDataReady: true,
        torReady: true,
        peerListenerReady: true,
        onionServiceReady: true,
        relayReady: true,
        generation: 1,
        detail: 'test runtime ready',
      );
  @override
  Future<RuntimeIdentity?> identity() async => null;
  @override
  Future<RuntimeProfile?> profile() async => null;
  @override
  Future<InviteCode?> refreshPairingCode() async => null;
  @override
  Future<RuntimeProfile> setNickname(String nickname) async =>
      const RuntimeProfile();
  @override
  Future<PairingItem> submitPairingCode(String code) async =>
      const PairingItem(id: '', status: InviteState.pending);
  @override
  Future<List<PairingItem>> pairingInbox() async => const [];
  @override
  Future<List<PairingItem>> pairingOutbox() async => const [];
  @override
  Future<PeerEndpoint?> peerEndpoint() async => null;
  @override
  Future<bool> peerEndpointAvailable() async => false;
  @override
  Future<void> retryPeerConnection(String installationId) async {}
  @override
  Future<void> rotatePeerEndpoint() async {}
  @override
  Future<void> acceptPairing(String pairingId) async {}
  @override
  Future<void> rejectPairing(String pairingId) async {}
  @override
  Future<void> cancelPairing(String pairingId) async {}
  @override
  Future<void> archivePairing(String pairingId) async {}
  @override
  Future<void> verifyContact(String installationId) async {}
  @override
  Future<ContactEndpointCapabilityStatus> contactEndpointCapability(
    String installationId,
  ) async => const ContactEndpointCapabilityStatus(
    contactId: '',
    capabilityId: '',
    sequence: 0,
    status: CapabilityStatus.missing,
  );
  @override
  Future<void> rotateContactEndpointCapability(String installationId) async {}
  @override
  Future<void> revokeContactEndpointCapability(String installationId) async {}
  @override
  Future<ContactRecord> updateContactSettings(
    String installationId, {
    String? localAlias,
    required bool muted,
    required bool blocked,
    ContactTransportPolicy? transportPolicy,
  }) async => const ContactRecord(
    id: '',
    nickname: '',
    fingerprint: '',
    publicKey: '',
    verified: false,
  );
  @override
  Future<void> removeRelationship(
    String installationId, {
    required bool preserveHistory,
  }) async {}
  @override
  Future<List<ContactRecord>> contacts() async => const [];
  @override
  Future<List<ConversationSummary>> conversations() async => const [];
  @override
  Future<List<ChatMessage>> messages(String id) async => const [];
  @override
  Future<void> openConversation(String id) async {}
  @override
  Future<void> closeConversation() async {}
  @override
  Future<void> startConversation(String contactId) async {}
  @override
  Future<void> sendMessage(
    String id,
    String text, {
    String? replyToMessageId,
  }) async {}
  @override
  Future<void> retryMessage(String messageId) async {}
  @override
  Future<void> deleteMessageLocal(String messageId) async {}
  @override
  Future<void> setTyping(String conversationId, bool typing) async {}
  @override
  Future<void> setPresence(bool online) async {}
  @override
  Future<void> sendReadReceipts(String conversationId) async {}
  @override
  Future<void> updateAppVisibility(bool foreground) async {}
}

class _AttachedRuntime extends _SplashRuntime
    implements RuntimeAttachmentProvider {
  const _AttachedRuntime();

  static const identityValue = RuntimeIdentity(
    installationId: 'alice-device',
    fingerprint: 'AA:BB',
    publicKey: 'alice-public-key',
  );
  static const profileValue = RuntimeProfile(
    installationId: 'alice-device',
    nickname: 'Alice',
    fingerprint: 'AA:BB',
    publicKey: 'alice-public-key',
  );
  static const contactValue = ContactRecord(
    id: 'bob-device',
    nickname: 'Bob',
    fingerprint: 'CC:DD',
    publicKey: 'bob-public-key',
    verified: true,
  );
  static const conversationValue = ConversationSummary(
    id: 'bob-device',
    contactId: 'bob-device',
    preview: 'Wiadomość ze snapshotu',
    unread: 1,
  );

  @override
  Future<Map<String, dynamic>?> runtimeSnapshot() async {
    final snapshot = <String, dynamic>{
      'serviceAlive': true,
      'localDataReady': true,
      'generation': 10,
      'createdAtMs': 10,
      'identity': {
        'installationId': identityValue.installationId,
        'fingerprint': identityValue.fingerprint,
        'publicKey': identityValue.publicKey,
      },
      'profile': {
        'installationId': profileValue.installationId,
        'nickname': profileValue.nickname,
        'fingerprint': profileValue.fingerprint,
        'publicKey': profileValue.publicKey,
      },
      'contacts': [
        {
          'installationId': contactValue.id,
          'nickname': contactValue.nickname,
          'fingerprint': contactValue.fingerprint,
          'publicKey': contactValue.publicKey,
          'verification': 'VERIFIED',
        },
      ],
      'conversations': [
        {
          'id': conversationValue.id,
          'contactInstallationId': conversationValue.contactId,
          'lastMessagePreview': conversationValue.preview,
          'unreadCount': conversationValue.unread,
          'status': 'ACTIVE',
        },
      ],
      'peerEndpointAvailable': true,
    };
    hydrateApplicationSnapshotMap(snapshot);
    return snapshot;
  }

  @override
  Future<RuntimeIdentity?> identity() async => identityValue;
  @override
  Future<RuntimeProfile?> profile() async => profileValue;
  @override
  Future<List<ContactRecord>> contacts() async => const [contactValue];
  @override
  Future<List<ConversationSummary>> conversations() async => const [
    conversationValue,
  ];
  @override
  Future<bool> peerEndpointAvailable() async => true;
}

void main() {
  setUp(ApplicationStateStore.shared.clear);

  testWidgets('shows TorChat splash before runtime bootstrap', (tester) async {
    await tester.pumpWidget(const TorChatMobileApp(runtime: _SplashRuntime()));
    expect(find.text('Prywatne wiadomości przez Tor'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets(
    'reattached profile remains gated until live readiness is proven',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const TorChatMobileApp(runtime: _AttachedRuntime()),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Bob'), findsNothing);
      expect(find.text('Wiadomość ze snapshotu'), findsNothing);
      expect(find.text('Rozgrzewanie TorChat'), findsWidgets);
    },
  );
}
