import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'contact_presence_snapshot.dart';

class ContactPresenceStore extends ChangeNotifier {
  final Map<String, ContactPresenceSnapshot> _snapshots = {};

  ContactPresenceSnapshot snapshot(String contactId) =>
      _snapshots[contactId] ?? ContactPresenceSnapshot(contactId: contactId);

  Map<String, ContactPresenceSnapshot> get snapshots =>
      Map.unmodifiable(_snapshots);

  void publish(ContactPresenceSnapshot value) {
    final previous = _snapshots[value.contactId];
    if (previous == value ||
        (previous != null && previous.revision > value.revision)) {
      return;
    }
    _snapshots[value.contactId] = value;
    notifyListeners();
  }
}

final contactPresenceStoreProvider =
    ChangeNotifierProvider<ContactPresenceStore>(
      (ref) => ContactPresenceStore(),
    );
