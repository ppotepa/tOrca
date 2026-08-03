enum ContactAvailability { unknown, checking, active, idle, offline }

enum ContactPeerLink {
  unknown,
  connecting,
  authenticating,
  connected,
  backoff,
  offline,
}

class ContactPresenceSnapshot {
  const ContactPresenceSnapshot({
    required this.contactId,
    this.availability = ContactAvailability.unknown,
    this.peerLink = ContactPeerLink.unknown,
    this.isViewingConversation = false,
    this.lastSeenAt,
    this.lastPeerConnectedAt,
    this.observedAt,
    this.expiresAt,
    this.latencyMs,
    this.revision = 0,
  });

  final String contactId;
  final ContactAvailability availability;
  final ContactPeerLink peerLink;
  final bool isViewingConversation;
  final int? lastSeenAt;
  final int? lastPeerConnectedAt;
  final int? observedAt;
  final int? expiresAt;
  final int? latencyMs;
  final int revision;

  ContactPresenceSnapshot copyWith({
    ContactAvailability? availability,
    ContactPeerLink? peerLink,
    bool? isViewingConversation,
    int? lastSeenAt,
    int? lastPeerConnectedAt,
    int? observedAt,
    int? expiresAt,
    int? latencyMs,
    int? revision,
  }) => ContactPresenceSnapshot(
    contactId: contactId,
    availability: availability ?? this.availability,
    peerLink: peerLink ?? this.peerLink,
    isViewingConversation: isViewingConversation ?? this.isViewingConversation,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    lastPeerConnectedAt: lastPeerConnectedAt ?? this.lastPeerConnectedAt,
    observedAt: observedAt ?? this.observedAt,
    expiresAt: expiresAt ?? this.expiresAt,
    latencyMs: latencyMs ?? this.latencyMs,
    revision: revision ?? this.revision,
  );
}
