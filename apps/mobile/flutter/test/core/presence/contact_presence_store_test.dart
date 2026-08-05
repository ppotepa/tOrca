import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/core/presence/contact_presence_snapshot.dart';
import 'package:torchat_mobile/core/presence/contact_presence_store.dart';

void main() {
  test('returns an unknown snapshot for an unseen contact', () {
    final store = ContactPresenceStore();

    expect(
      store.snapshot('contact-a').availability,
      ContactAvailability.unknown,
    );
    expect(store.snapshot('contact-a').peerLink, ContactPeerLink.unknown);
  });

  test('ignores an older revision and publishes a newer revision', () {
    final store = ContactPresenceStore();
    var notifications = 0;
    store.addListener(() => notifications++);

    store.publish(
      const ContactPresenceSnapshot(
        contactId: 'contact-a',
        availability: ContactAvailability.active,
        revision: 2,
      ),
    );
    store.publish(
      const ContactPresenceSnapshot(
        contactId: 'contact-a',
        availability: ContactAvailability.offline,
        revision: 1,
      ),
    );

    expect(
      store.snapshot('contact-a').availability,
      ContactAvailability.active,
    );
    expect(notifications, 1);

    store.publish(
      const ContactPresenceSnapshot(
        contactId: 'contact-a',
        availability: ContactAvailability.idle,
        revision: 3,
      ),
    );
    expect(store.snapshot('contact-a').availability, ContactAvailability.idle);
    expect(notifications, 2);
  });
}
