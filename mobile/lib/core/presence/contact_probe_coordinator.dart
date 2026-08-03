import 'dart:async';
import 'dart:developer' as developer;

import '../models/domain.dart';
import '../runtime/generated/runtime_contract.g.dart';
import 'contact_presence_snapshot.dart';
import 'contact_presence_store.dart';

class ContactProbeCoordinator {
  ContactProbeCoordinator(this.store);

  final ContactPresenceStore store;
  final Map<String, Timer> _expiry = {};
  final Map<String, int> _sequence = {};
  final Map<String, String> _conversationContacts = {};

  void bindConversation(String conversationId, String contactId) {
    if (conversationId.isNotEmpty && contactId.isNotEmpty) {
      _conversationContacts[conversationId] = contactId;
    }
  }

  /// Reattaches expiry management to the retained snapshots after the engine
  /// stream is recreated. A missing/expired observation remains unknown.
  void reattach() {
    for (final snapshot in store.snapshots.values) {
      if (snapshot.expiresAt != null) {
        _scheduleExpiry(snapshot.contactId, snapshot.expiresAt);
      }
    }
  }

  void dispose() {
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _expiry.clear();
  }

  void accept(RuntimeEvent event) {
    switch (event) {
      case DataChangedEvent(:final type, :final payload):
        if (type == EngineContract.presenceChanged) {
          _presence(payload);
        } else if (type == EngineContract.conversationFocusChanged) {
          _focus(payload);
        } else if (type == EngineContract.peerConnectionChanged) {
          _peer(payload);
        }
      case PeerConnectionChangedEvent(:final contactId, :final status):
        _setPeer(contactId, status.name);
      default:
        break;
    }
  }

  void _presence(Map<String, dynamic> payload) {
    final id = payload[EngineContract.contactId]?.toString();
    if (id == null || id.isEmpty) {
      _logEvent('contact_presence_event_discarded', null, source: 'presence');
      return;
    }
    final online = payload[EngineContract.online] == true;
    final idle = online && payload[EngineContract.idle] == true;
    final observed = (payload[EngineContract.observedAt] as num?)?.toInt();
    final expires = (payload[EngineContract.expiresAt] as num?)?.toInt();
    _publish(
      id,
      store
          .snapshot(id)
          .copyWith(
            availability: online
                ? (idle ? ContactAvailability.idle : ContactAvailability.active)
                : ContactAvailability.offline,
            lastSeenAt: observed,
            observedAt: observed,
            expiresAt: expires,
            revision: _next(id),
          ),
    );
    _scheduleExpiry(id, expires);
  }

  void _focus(Map<String, dynamic> payload) {
    final conversationId = payload[EngineContract.conversationId]?.toString();
    final id =
        payload[EngineContract.contactId]?.toString() ??
        (conversationId == null ? null : _conversationContacts[conversationId]);
    if (id == null || id.isEmpty) return;
    _publish(
      id,
      store
          .snapshot(id)
          .copyWith(
            isViewingConversation: payload[EngineContract.focused] == true,
            revision: _next(id),
          ),
    );
  }

  void _peer(Map<String, dynamic> payload) {
    final id = payload[EngineContract.contactId]?.toString();
    if (id != null && id.isNotEmpty) {
      _setPeer(id, payload[EngineContract.status]?.toString() ?? 'unknown');
    }
  }

  void _setPeer(String id, String status) {
    final link = ContactPeerLink.values.firstWhere(
      (value) => value.name == status,
      orElse: () => ContactPeerLink.unknown,
    );
    final old = store.snapshot(id);
    _publish(
      id,
      old.copyWith(
        peerLink: link,
        lastPeerConnectedAt: link == ContactPeerLink.connected
            ? DateTime.now().millisecondsSinceEpoch
            : old.lastPeerConnectedAt,
        revision: _next(id),
      ),
    );
    _logEvent('contact_peer_link_updated', id, source: 'peer_connection');
  }

  void _scheduleExpiry(String id, int? expiresAt) {
    _expiry.remove(id)?.cancel();
    if (expiresAt == null) return;
    final delay = expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (delay <= 0) {
      _expire(id, expiresAt);
    } else {
      _expiry[id] = Timer(
        Duration(milliseconds: delay),
        () => _expire(id, expiresAt),
      );
    }
  }

  void _expire(String id, int expiresAt) {
    final current = store.snapshot(id);
    if (current.expiresAt != expiresAt) return;
    _publish(
      id,
      current.copyWith(
        availability: ContactAvailability.unknown,
        revision: _next(id),
      ),
    );
    _log('contact_presence_expired', id, current);
    _expiry.remove(id);
  }

  int _next(String id) => (_sequence[id] ?? 0) + 1;

  void _publish(String id, ContactPresenceSnapshot value) {
    _sequence[id] = value.revision;
    store.publish(value);
    _log('contact_presence_updated', id, value);
  }

  void _logEvent(String event, String? contactId, {required String source}) {
    developer.log(
      event,
      name: 'torchat.presence',
      error: {
        'contactIdHash': contactId?.hashCode.toRadixString(16),
        'source': source,
        'revision': contactId == null ? null : (_sequence[contactId] ?? 0),
      },
    );
  }

  void _log(String event, String contactId, ContactPresenceSnapshot snapshot) {
    developer.log(
      event,
      name: 'torchat.presence',
      error: {
        'contactIdHash': contactId.hashCode.toRadixString(16),
        'availability': snapshot.availability.name,
        'peerLink': snapshot.peerLink.name,
        'observedAt': snapshot.observedAt,
        'expiresAt': snapshot.expiresAt,
        'latencyMs': snapshot.latencyMs,
        'revision': snapshot.revision,
      },
    );
  }
}
