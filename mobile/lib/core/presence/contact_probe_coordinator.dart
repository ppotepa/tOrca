import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:cryptography/cryptography.dart';

import '../models/domain.dart';
import '../runtime/generated/runtime_contract.g.dart';
import 'contact_presence_snapshot.dart';
import 'contact_presence_store.dart';

class ContactProbeCoordinator {
  ContactProbeCoordinator(this.store);

  final ContactPresenceStore store;
  final Map<String, Timer> _expiry = {};
  final Map<String, Timer> _focusExpiry = {};
  final Map<String, int> _focusExpiresAt = {};
  final Map<String, int> _sequence = {};
  final Map<String, int> _wireSequence = {};
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
      _sequence[snapshot.contactId] = snapshot.revision;
      if (snapshot.expiresAt != null) {
        _scheduleExpiry(snapshot.contactId, snapshot.expiresAt);
      }
    }
  }

  void dispose() {
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    for (final timer in _focusExpiry.values) {
      timer.cancel();
    }
    _expiry.clear();
    _focusExpiry.clear();
    _focusExpiresAt.clear();
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
      case PeerConnectionChangedEvent(
        :final contactId,
        :final status,
        :final retryInMs,
      ):
        _setPeer(contactId, status.name, retryInMs: retryInMs);
      case PeerEndpointChangedEvent(:final contactId, :final status):
        _touchTechnical(contactId, 'endpoint:${status.name}');
      case ContactCapabilityChangedEvent(:final contactId, :final status):
        _touchTechnical(contactId, 'capability:${status.name}');
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
    final wireSequence = (payload[EngineContract.sequence] as num?)?.toInt();
    final current = store.snapshot(id);
    if ((observed != null &&
            current.observedAt != null &&
            observed < current.observedAt!) ||
        (wireSequence != null && wireSequence <= (_wireSequence[id] ?? 0))) {
      _logEvent('contact_presence_event_discarded', id, source: 'stale');
      return;
    }
    if (wireSequence != null) _wireSequence[id] = wireSequence;
    _publish(
      id,
      current.copyWith(
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
    final focused = payload[EngineContract.focused] == true;
    final expires = (payload[EngineContract.expiresAt] as num?)?.toInt();
    final previousExpires = _focusExpiresAt[id];
    if (expires != null &&
        previousExpires != null &&
        expires < previousExpires) {
      _logEvent('contact_presence_event_discarded', id, source: 'stale_focus');
      return;
    }
    if (focused && expires != null) {
      _focusExpiresAt[id] = expires;
    } else if (focused) {
      _focusExpiresAt.remove(id);
    } else if (!focused) {
      _focusExpiresAt.remove(id);
    }
    _publish(
      id,
      store
          .snapshot(id)
          .copyWith(isViewingConversation: focused, revision: _next(id)),
    );
    _focusExpiry.remove(id)?.cancel();
    if (focused && expires != null) {
      final delay = expires - DateTime.now().millisecondsSinceEpoch;
      _focusExpiry[id] = Timer(
        Duration(milliseconds: delay < 0 ? 0 : delay),
        () {
          final current = store.snapshot(id);
          if (!current.isViewingConversation) return;
          _publish(
            id,
            current.copyWith(isViewingConversation: false, revision: _next(id)),
          );
          _focusExpiresAt.remove(id);
          _focusExpiry.remove(id);
        },
      );
    }
  }

  void _peer(Map<String, dynamic> payload) {
    final id = payload[EngineContract.contactId]?.toString();
    if (id != null && id.isNotEmpty) {
      _setPeer(
        id,
        payload[EngineContract.status]?.toString() ?? 'unknown',
        retryInMs: (payload[EngineContract.retryInMs] as num?)?.toInt(),
      );
    }
  }

  void _setPeer(String id, String status, {int? retryInMs}) {
    final link = ContactPeerLink.values.firstWhere(
      (value) => value.name == status,
      orElse: () => ContactPeerLink.unknown,
    );
    final old = store.snapshot(id);
    _publish(
      id,
      old.copyWith(
        peerLink: link,
        retryInMs: retryInMs,
        clearRetryInMs: true,
        lastPeerConnectedAt: link == ContactPeerLink.connected
            ? DateTime.now().millisecondsSinceEpoch
            : old.lastPeerConnectedAt,
        revision: _next(id),
      ),
    );
    _logEvent('contact_peer_link_updated', id, source: 'peer_connection');
    switch (link) {
      case ContactPeerLink.connecting:
      case ContactPeerLink.authenticating:
        _logEvent('contact_probe_started', id, source: link.name);
      case ContactPeerLink.connected:
        _logEvent('contact_probe_finished', id, source: 'peer_connection');
      case ContactPeerLink.backoff:
        _logEvent('contact_probe_backoff', id, source: 'peer_connection');
      case ContactPeerLink.unknown:
      case ContactPeerLink.offline:
        break;
    }
  }

  /// Endpoint and capability facts are technical projections. They refresh
  /// subscribers for the inspector, but must never promote a contact to
  /// active/idle or change the peer link on their own.
  void _touchTechnical(String id, String source) {
    if (id.isEmpty) return;
    final current = store.snapshot(id);
    _publish(id, current.copyWith(revision: _next(id)));
    _logEvent('contact_technical_updated', id, source: source);
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
        clearExpiry: true,
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
    unawaited(_logEventWithDigest(event, contactId, source: source));
  }

  void _log(String event, String contactId, ContactPresenceSnapshot snapshot) {
    unawaited(_logWithDigest(event, contactId, snapshot));
  }

  Future<void> _logEventWithDigest(
    String event,
    String? contactId, {
    required String source,
  }) async {
    developer.log(
      event,
      name: 'torchat.presence',
      error: {
        'contactIdHash': contactId == null ? null : await _digest(contactId),
        'source': source,
        'revision': contactId == null ? null : (_sequence[contactId] ?? 0),
      },
    );
  }

  Future<void> _logWithDigest(
    String event,
    String contactId,
    ContactPresenceSnapshot snapshot,
  ) async {
    developer.log(
      event,
      name: 'torchat.presence',
      error: {
        'contactIdHash': await _digest(contactId),
        'availability': snapshot.availability.name,
        'peerLink': snapshot.peerLink.name,
        'observedAt': snapshot.observedAt,
        'expiresAt': snapshot.expiresAt,
        'latencyMs': snapshot.latencyMs,
        'revision': snapshot.revision,
      },
    );
  }

  Future<String> _digest(String value) async {
    final hash = await Sha256().hash(utf8.encode(value));
    return hash.bytes
        .take(8)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
