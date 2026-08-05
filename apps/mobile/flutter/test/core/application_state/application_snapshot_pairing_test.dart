import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_flutter_ui/core/application_state/application_snapshot.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import 'package:torchat_mobile/core/application_state/application_state_store.dart';

PairingItem pairing(String id, PairingOrigin origin) => PairingItem(
  id: id,
  status: InviteState.pending,
  origin: origin,
);

void main() {
  test('equal revision cannot replace authoritative pairing collections', () {
    final store = ApplicationStateStore();
    final first = store.hydrate(
      ApplicationSnapshot(
        schemaVersion: 2,
        projectionStoreId: 'store-1',
        projectionRevision: 5,
        pairingInbox: [pairing('first', PairingOrigin.inbox)],
      ),
    );
    final duplicate = store.hydrate(
      ApplicationSnapshot(
        schemaVersion: 2,
        projectionStoreId: 'store-1',
        projectionRevision: 5,
        pairingInbox: [pairing('second', PairingOrigin.inbox)],
      ),
    );

    expect(first, isTrue);
    expect(duplicate, isFalse);
    expect(store.pairingInbox.single.id, 'first');
  });

  test('new store may replace a higher revision from the previous store', () {
    final store = ApplicationStateStore();
    store.hydrate(
      ApplicationSnapshot(
        schemaVersion: 2,
        projectionStoreId: 'store-old',
        projectionRevision: 100,
        pairingInbox: [pairing('old', PairingOrigin.inbox)],
      ),
    );

    final accepted = store.hydrate(
      ApplicationSnapshot(
        schemaVersion: 2,
        projectionStoreId: 'store-new',
        projectionRevision: 1,
        pairingInbox: [pairing('new', PairingOrigin.inbox)],
      ),
    );

    expect(accepted, isTrue);
    expect(store.pairingInbox.single.id, 'new');
  });

  test('schema two empty pairing projection overrides schema one fallback', () {
    final store = ApplicationStateStore();
    store.setPairing(
      [pairing('legacy-inbox', PairingOrigin.inbox)],
      [pairing('legacy-outbox', PairingOrigin.outbox)],
    );

    store.hydrate(
      const ApplicationSnapshot(
        schemaVersion: 2,
        projectionStoreId: 'store-1',
        projectionRevision: 1,
      ),
    );

    expect(store.pairingInbox, isEmpty);
    expect(store.pairingOutbox, isEmpty);
  });
}
