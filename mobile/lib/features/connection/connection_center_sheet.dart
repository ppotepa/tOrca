import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../app/application_snapshot_provider.dart';
import '../../app/notifications/ui_notification_center.dart';
import '../../app/ui_operation_registry.dart';
import '../../core/application_state/application_snapshot.dart';
import '../../core/connection/app_state_connection.dart';
import '../../core/connection/connection_component.dart';
import '../../core/models/domain.dart';
import '../../core/presence/contact_presence_snapshot.dart';
import '../../core/presence/contact_presence_store.dart';
import '../../shared/async/busy_action_button.dart';

class ConnectionCenterSheet extends ConsumerWidget {
  const ConnectionCenterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final snapshot = ref.watch(applicationSnapshotProvider).valueOrNull;
    final controller = ref.read(appControllerProvider.notifier);
    final presence = ref.watch(contactPresenceStoreProvider);
    final retryState = ref.watch(
      uiOperationProvider(UiOperationKey.connectionRetry),
    );
    final readiness = state.connectionReadiness;
    final summary = state.connectionSummary;
    final contacts = snapshot?.contacts ?? const <ContactRecord>[];
    final conversations =
        snapshot?.conversations ?? const <ConversationSummary>[];
    final queued = state.messages
        .where(
          (message) =>
              message.state == MessageState.queued ||
              message.state == MessageState.sending,
        )
        .length;
    final failed = state.messages
        .where((message) => message.state == MessageState.failed)
        .length;
    final directSessions = contacts
        .where(
          (contact) =>
              contact.peerConnectionStatus == PeerConnectionStatus.connected,
        )
        .length;
    final onlineContacts = presence.snapshots.values
        .where(
          (value) =>
              value.availability == ContactAvailability.active ||
              value.availability == ContactAvailability.idle,
        )
        .length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Centrum połączeń',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                summary.status,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                summary.detail,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Text(
                'Infrastruktura aplikacji',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              for (final component in readiness.components)
                _ConnectionComponentTile(status: component),
              _StatusTile(
                icon: Icons.forum_outlined,
                title: 'Gotowość komunikacji',
                state: readiness.communicationReady
                    ? 'ready'
                    : readiness.failed
                    ? 'failed'
                    : readiness.degraded
                    ? 'degraded'
                    : 'starting',
                detail: readiness.communicationReady
                    ? 'Wszystkie wymagane komponenty startowe są gotowe.'
                    : readiness.startupSteps.last.detail,
              ),
              const Divider(height: 30),
              Text(
                'Aktywność w aplikacji',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              _StatusTile(
                icon: Icons.cable_outlined,
                title: 'Bezpośrednie sesje kontaktów',
                state: '$directSessions/${contacts.length}',
                detail:
                    'Sesje z konkretnymi kontaktami powstają po onboardingu i nie blokują startu aplikacji.',
              ),
              _StatusTile(
                icon: Icons.people_alt_outlined,
                title: 'Obecność kontaktów',
                state: '$onlineContacts/${contacts.length}',
                detail: 'Kontakty zgłaszające aktywną obecność w runtime.',
              ),
              _StatusTile(
                icon: Icons.forum_outlined,
                title: 'Lokalne podsumowania rozmów',
                state: '${conversations.length}',
                detail:
                    'Lista rozmów pochodzi z atomowego snapshotu; wiadomości są ładowane dopiero po otwarciu.',
              ),
              _StatusTile(
                icon: Icons.queue_outlined,
                title: 'Kolejka wiadomości',
                state: queued == 0 && failed == 0
                    ? 'czysta'
                    : '$queued oczekuje · $failed błędów',
                detail:
                    'Wiadomości pozostają w trwałej kolejce do czasu potwierdzenia dostawy.',
              ),
              if (state.error.isNotEmpty)
                _StatusTile(
                  icon: Icons.error_outline,
                  title: 'Ostatni błąd',
                  state: 'error',
                  detail: state.error,
                ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final diagnostic = _diagnosticText(state, snapshot);
                      await Clipboard.setData(ClipboardData(text: diagnostic));
                      if (context.mounted) {
                        ref
                            .read(uiNotificationCenterProvider.notifier)
                            .showSuccess(
                              'Diagnostyka skopiowana.',
                              deduplicationKey: 'diagnostics-copied',
                            );
                      }
                    },
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Kopiuj diagnostykę'),
                  ),
                  BusyActionButton(
                    busy: retryState.busy,
                    label: 'Ponów połączenie',
                    busyLabel: 'Ponawianie…',
                    icon: const Icon(Icons.refresh),
                    onPressed: state.isLoading ? null : controller.retryTor,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _diagnosticText(AppState state, ApplicationSnapshot? snapshot) {
    final readiness = state.connectionReadiness;
    final contacts = snapshot?.contacts ?? const <ContactRecord>[];
    final conversations =
        snapshot?.conversations ?? const <ConversationSummary>[];
    final components = readiness.components
        .map(
          (component) =>
              '${component.component.name}=${component.state.name}:${component.detail}',
        )
        .join('\n');
    final directSessions = contacts
        .where(
          (contact) =>
              contact.peerConnectionStatus == PeerConnectionStatus.connected,
        )
        .length;
    return [
      'screen=${state.screen.name}',
      'snapshotGeneration=${snapshot?.generation ?? 0}',
      'snapshotCreatedAt=${snapshot?.createdAtMs ?? 0}',
      'localCoreReady=${readiness.localCoreReady}',
      'onboardingReady=${readiness.onboardingReady}',
      'communicationReady=${readiness.communicationReady}',
      'contacts=${contacts.length}',
      'directSessions=$directSessions',
      'conversations=${conversations.length}',
      'pendingInbox=${snapshot?.pendingInbox ?? state.inbox.length}',
      'pendingOutbox=${snapshot?.pendingOutbox ?? state.outbox.length}',
      'error=${state.error}',
      components,
    ].join('\n');
  }
}

class _ConnectionComponentTile extends StatelessWidget {
  const _ConnectionComponentTile({required this.status});

  final ConnectionComponentStatus status;

  @override
  Widget build(BuildContext context) => _StatusTile(
    icon: _icon(status.component),
    title: status.component.title,
    state: status.state.name,
    detail: status.detail.isEmpty
        ? status.component.description
        : status.detail,
    trailing: status.progress == null ? null : '${status.progress}%',
  );

  IconData _icon(ConnectionComponent component) => switch (component) {
    ConnectionComponent.engine => Icons.memory_outlined,
    ConnectionComponent.localData => Icons.storage_outlined,
    ConnectionComponent.tor => Icons.hub_outlined,
    ConnectionComponent.relay => Icons.cloud_sync_outlined,
    ConnectionComponent.peerListener => Icons.cell_tower_outlined,
    ConnectionComponent.onionService => Icons.security_outlined,
  };
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.title,
    required this.state,
    required this.detail,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String state;
  final String detail;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final normalized = state.toLowerCase();
    final color = normalized.contains('ready') || normalized == 'czysta'
        ? scheme.primary
        : normalized.contains('error') || normalized.contains('failed')
        ? scheme.error
        : scheme.tertiary;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: Text(detail),
      trailing: Text(
        trailing ?? state,
        style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }
}
