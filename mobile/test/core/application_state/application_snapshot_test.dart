import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/application_state/application_snapshot.dart';
import 'package:torchat_mobile/core/application_state/application_snapshot_patch.dart';
import 'package:torchat_mobile/core/application_state/application_state_store.dart';
import 'package:torchat_mobile/core/models/domain.dart';

void main() {
  test(
    'application watcher retains state and cannot miss later snapshots',
    () async {
      final store = ApplicationStateStore();
      store.hydrate(const ApplicationSnapshot(generation: 1));
      final generations = <int?>[];

      final subscription = store.watchApplication().listen(
        (snapshot) => generations.add(snapshot?.generation),
      );
      store.hydrate(const ApplicationSnapshot(generation: 2));
      await Future<void>.delayed(Duration.zero);

      expect(generations, [1, 2]);
      subscription.cancel();
    },
  );

  test('store rejects snapshots older than the hydrated generation', () {
    final store = ApplicationStateStore();
    store.hydrate(
      const ApplicationSnapshot(
        generation: 4,
        profile: RuntimeProfile(nickname: 'Alice'),
      ),
    );
    store.hydrate(
      const ApplicationSnapshot(
        generation: 3,
        profile: RuntimeProfile(nickname: 'Stale'),
      ),
    );

    expect(store.current?.generation, 4);
    expect(store.current?.profile.nickname, 'Alice');
  });

  test('newer engine projection wins over a synthetic generation', () {
    final store = ApplicationStateStore();
    store.hydrate(
      const ApplicationSnapshot(
        generation: 20,
        projectionStoreId: 'engine-store',
        projectionRevision: 4,
      ),
    );

    final accepted = store.hydrate(
      const ApplicationSnapshot(
        generation: 3,
        projectionStoreId: 'engine-store',
        projectionRevision: 5,
        contacts: [
          ContactRecord(
            id: 'bob',
            nickname: 'Bob',
            fingerprint: 'AA',
            publicKey: 'key',
            verified: true,
          ),
        ],
      ),
    );

    expect(accepted, isTrue);
    expect(store.current?.projectionRevision, 5);
    expect(store.current?.contacts.single.id, 'bob');
  });

  test('older engine projection loses despite a newer generation', () {
    final store = ApplicationStateStore();
    store.hydrate(
      const ApplicationSnapshot(
        generation: 3,
        projectionStoreId: 'engine-store',
        projectionRevision: 5,
      ),
    );

    final accepted = store.hydrate(
      const ApplicationSnapshot(
        generation: 30,
        projectionStoreId: 'engine-store',
        projectionRevision: 4,
      ),
    );

    expect(accepted, isFalse);
    expect(store.current?.projectionRevision, 5);
  });

  test('authoritative projection replaces a legacy higher generation', () {
    final store = ApplicationStateStore();
    store.hydrate(const ApplicationSnapshot(generation: 100));

    final accepted = store.hydrate(
      const ApplicationSnapshot(
        generation: 1,
        projectionStoreId: 'engine-store',
        projectionRevision: 1,
      ),
    );

    expect(accepted, isTrue);
    expect(store.current?.projectionStoreId, 'engine-store');
  });

  test('store marks retained shell stale without deleting visible data', () {
    final store = ApplicationStateStore();
    store.hydrate(
      const ApplicationSnapshot(
        generation: 1,
        contacts: [
          ContactRecord(
            id: 'bob',
            nickname: 'Bob',
            fingerprint: 'AA',
            publicKey: 'key',
            verified: true,
          ),
        ],
      ),
    );

    store.markStale();

    expect(store.isStale, isTrue);
    expect(store.current?.contacts.single.nickname, 'Bob');
  });

  test('generation patch replaces shell atomically', () {
    final store = ApplicationStateStore();
    const current = ApplicationSnapshot(
      generation: 7,
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
    );
    const next = ApplicationSnapshot(
      generation: 8,
      profile: RuntimeProfile(nickname: 'Alice'),
      contacts: [
        ContactRecord(
          id: 'bob',
          nickname: 'Robert',
          fingerprint: 'AA',
          publicKey: 'key',
          verified: true,
        ),
      ],
      conversations: [
        ConversationSummary(
          id: 'conversation',
          contactId: 'bob',
          preview: 'Nowa wiadomość',
          unread: 1,
        ),
      ],
    );
    store.hydrate(current);

    expect(
      store.applyPatch(ApplicationSnapshotPatch.replace(current, next)),
      isTrue,
    );
    expect(store.current?.generation, 8);
    expect(store.current?.contacts.single.nickname, 'Robert');
    expect(store.current?.conversations.single.unread, 1);
  });

  test('patch with a generation gap is rejected', () {
    final store = ApplicationStateStore();
    store.hydrate(const ApplicationSnapshot(generation: 2));

    final accepted = store.applyPatch(
      const ApplicationSnapshotPatch(
        baseGeneration: 1,
        generation: 3,
        createdAtMs: 3,
      ),
    );

    expect(accepted, isFalse);
    expect(store.current?.generation, 2);
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
