import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/application_state/application_snapshot.dart';
import 'package:torchat_mobile/core/application_state/application_state_store.dart';
import 'package:torchat_mobile/core/models/domain.dart';

void main() {
  test('store rejects snapshots older than the hydrated generation', () {
    final store = ApplicationStateStore();
    store.hydrate(const ApplicationSnapshot(
      generation: 4,
      profile: RuntimeProfile(nickname: 'Alice'),
    ));
    store.hydrate(const ApplicationSnapshot(
      generation: 3,
      profile: RuntimeProfile(nickname: 'Stale'),
    ));

    expect(store.current?.generation, 4);
    expect(store.current?.profile.nickname, 'Alice');
  });

  test('shell snapshot intentionally excludes messages', () {
    const snapshot = ApplicationSnapshot(
      generation: 1,
      profile: RuntimeProfile(nickname: 'Alice'),
      contacts: [
        ContactRecord(
          id: 'bob',
          nickname: 'Bob',
          fingerprint: 'AA',
          publicKey: 'key',
          verified: true,
        ),
      ],
      conversations: [
        ConversationSummary(
          id: 'conversation',
          contactId: 'bob',
          preview: 'Ostatnia wiadomość',
          unread: 1,
        ),
      ],
    );

    expect(snapshot.hasProfile, isTrue);
    expect(snapshot.contacts, hasLength(1));
    expect(snapshot.conversations, hasLength(1));
  });
}
