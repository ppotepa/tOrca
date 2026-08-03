import 'package:flutter_test/flutter_test.dart';

import 'package:torchat_mobile/core/models/domain.dart';
import 'package:torchat_mobile/core/presence/contact_probe_coordinator.dart';
import 'package:torchat_mobile/core/presence/contact_presence_snapshot.dart';
import 'package:torchat_mobile/core/presence/contact_presence_store.dart';
import 'package:torchat_mobile/core/runtime/generated/runtime_contract.g.dart';

void main() {
  test('presence maps to active and expires to unknown', () async {
    final store = ContactPresenceStore();
    final coordinator = ContactProbeCoordinator(store);
    final expires = DateTime.now().millisecondsSinceEpoch + 20;

    coordinator.accept(
      DataChangedEvent(EngineContract.presenceChanged, {
        EngineContract.contactId: 'contact-a',
        EngineContract.online: true,
        EngineContract.idle: false,
        EngineContract.observedAt: DateTime.now().millisecondsSinceEpoch,
        EngineContract.expiresAt: expires,
      }),
    );
    expect(
      store.snapshot('contact-a').availability,
      ContactAvailability.active,
    );

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      store.snapshot('contact-a').availability,
      ContactAvailability.unknown,
    );
    coordinator.dispose();
    store.dispose();
  });

  test('focus resolves conversation id to its contact only', () {
    final store = ContactPresenceStore();
    final coordinator = ContactProbeCoordinator(store);
    coordinator.bindConversation('conversation-a', 'contact-a');
    coordinator.bindConversation('conversation-b', 'contact-b');

    coordinator.accept(
      DataChangedEvent(EngineContract.conversationFocusChanged, {
        EngineContract.conversationId: 'conversation-a',
        EngineContract.focused: true,
      }),
    );

    expect(store.snapshot('contact-a').isViewingConversation, isTrue);
    expect(store.snapshot('contact-b').isViewingConversation, isFalse);
    coordinator.dispose();
    store.dispose();
  });

  test('peer connection does not change application availability', () {
    final store = ContactPresenceStore();
    final coordinator = ContactProbeCoordinator(store);

    coordinator.accept(
      const PeerConnectionChangedEvent(
        contactId: 'contact-a',
        status: PeerConnectionStatus.connected,
      ),
    );

    expect(store.snapshot('contact-a').peerLink, ContactPeerLink.connected);
    expect(
      store.snapshot('contact-a').availability,
      ContactAvailability.unknown,
    );
    coordinator.dispose();
    store.dispose();
  });
}
