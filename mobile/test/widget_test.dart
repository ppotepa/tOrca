import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/client_runtime.dart';
import 'package:torchat_mobile/main.dart';

class _SplashRuntime implements ClientRuntime, PairingTechnicalRuntime {
  const _SplashRuntime();

  @override
  Stream<RuntimeEvent> get events => const Stream.empty();
  @override
  Future<bool> connect() async => true;
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
  Future<PairingPreparation> prepareAcceptPairing(String pairingId) async =>
      const PairingPreparation(
        pairingId: '',
        recipientInstallationId: '',
        capability: '',
      );
  @override
  Future<PairingSendEffect> commitAcceptPairing(
    String pairingId,
    String offerInviteId,
    String offerPayload,
  ) async => const PairingSendEffect(
    pairingId: '',
    recipientInstallationId: '',
    kind: PairingSendKind.offer,
  );
  @override
  Future<PairingPreparation> prepareRejectPairing(String pairingId) async =>
      const PairingPreparation(
        pairingId: '',
        recipientInstallationId: '',
        capability: '',
      );
  @override
  Future<PairingSendEffect> commitRejectPairing(String pairingId) async =>
      const PairingSendEffect(
        pairingId: '',
        recipientInstallationId: '',
        kind: PairingSendKind.rejection,
      );
  @override
  Future<PairingCancelEffect> prepareCancelPairing(String pairingId) async =>
      const PairingCancelEffect(pairingId: '');
  @override
  Future<void> confirmPairingCancelled(String pairingId) async {}
  @override
  Future<void> verifyContact(String installationId) async {}
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
  Future<void> sendMessage(String id, String text) async {}
}

void main() {
  testWidgets('shows TorChat splash before runtime bootstrap', (tester) async {
    await tester.pumpWidget(const TorChatMobileApp(runtime: _SplashRuntime()));
    expect(find.text('TorChat'), findsOneWidget);
    expect(find.text('Prywatne wiadomości przez Tor'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
  });
}
