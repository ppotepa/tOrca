import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../app/application_snapshot_provider.dart';
import '../../app/notifications/ui_notification_center.dart';
import '../../app/ui_operation_registry.dart';
import 'package:torchat_flutter_ui/core/application_state/application_snapshot.dart';
import '../../core/connection/connection_component.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import '../../core/presence/contact_presence_snapshot.dart';
import '../../core/presence/contact_presence_store.dart';
import '../../locales/presentation/app_localizations_x.dart';
import '../../locales/presentation/state_problem_localizer.dart';
import '../../locales/presentation/status_localizer.dart';
import 'package:torchat_flutter_ui/async/busy_action_button.dart';

enum _StatusTone { success, warning, error, neutral }

class ConnectionCenterSheet extends ConsumerWidget {
  const ConnectionCenterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
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
    final activeContacts = presence.snapshots.values
        .where(
          (value) =>
              value.availability == ContactAvailability.active ||
              value.availability == ContactAvailability.idle,
        )
        .length;
    final localizedError = localizeStateProblem(
      l10n,
      problem: state.problem,
      diagnosticError: state.error,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.connectionCenterTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                localizeTransportPhase(l10n, summary.phase),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 20),
              Text(
                l10n.connectionInfrastructure,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              for (final component in readiness.components)
                _ConnectionComponentTile(status: component),
              _StatusTile(
                icon: Icons.forum_outlined,
                title: l10n.connectionCommunicationReadiness,
                state: readiness.communicationReady
                    ? l10n.uiStateReady
                    : readiness.failed
                    ? l10n.uiStateFailed
                    : readiness.degraded
                    ? l10n.uiStateDegraded
                    : l10n.uiStateStarting,
                tone: readiness.communicationReady
                    ? _StatusTone.success
                    : readiness.failed
                    ? _StatusTone.error
                    : _StatusTone.warning,
                detail: readiness.communicationReady
                    ? l10n.startupCommunicationDescription
                    : localizeStartupStepDescription(
                        l10n,
                        readiness.startupSteps.last.kind,
                      ),
              ),
              const Divider(height: 30),
              Text(
                l10n.connectionActivity,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              _StatusTile(
                icon: Icons.cable_outlined,
                title: l10n.connectionDirectSessions,
                state: '$directSessions/${contacts.length}',
                tone: directSessions > 0
                    ? _StatusTone.success
                    : _StatusTone.neutral,
                detail: l10n.connectionDirectSessionsDetail,
              ),
              _StatusTile(
                icon: Icons.people_alt_outlined,
                title: l10n.connectionContactPresence,
                state: '$activeContacts/${contacts.length}',
                tone: activeContacts > 0
                    ? _StatusTone.success
                    : _StatusTone.neutral,
                detail: l10n.connectionContactPresenceDetail,
              ),
              _StatusTile(
                icon: Icons.forum_outlined,
                title: l10n.connectionLocalConversationSummaries,
                state: '${conversations.length}',
                tone: _StatusTone.neutral,
                detail: l10n.connectionLocalConversationSummariesDetail,
              ),
              _StatusTile(
                icon: Icons.queue_outlined,
                title: l10n.connectionMessageQueue,
                state: queued == 0 && failed == 0
                    ? l10n.connectionQueueClean
                    : l10n.connectionQueueCounts(queued, failed),
                tone: failed > 0
                    ? _StatusTone.error
                    : queued > 0
                    ? _StatusTone.warning
                    : _StatusTone.success,
                detail: l10n.connectionMessageQueueDetail,
              ),
              if (localizedError != null)
                _StatusTile(
                  icon: Icons.error_outline,
                  title: l10n.connectionLastError,
                  state: l10n.uiStateError,
                  tone: _StatusTone.error,
                  detail: localizedError,
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
                              context.l10n.connectionDiagnosticsCopied,
                              deduplicationKey: 'diagnostics-copied',
                            );
                      }
                    },
                    icon: const Icon(Icons.copy_all_outlined),
                    label: Text(context.l10n.connectionCopyDiagnostics),
                  ),
                  BusyActionButton(
                    busy: retryState.busy,
                    label: context.l10n.connectionRetry,
                    busyLabel: context.l10n.connectionRetrying,
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
  Widget build(BuildContext context) {
    final stateName = status.state.name.toLowerCase();
    final tone = stateName.contains('ready')
        ? _StatusTone.success
        : stateName.contains('failed') || stateName.contains('error')
        ? _StatusTone.error
        : _StatusTone.warning;
    final localizedState = switch (tone) {
      _StatusTone.success => context.l10n.uiStateReady,
      _StatusTone.error => context.l10n.uiStateFailed,
      _StatusTone.warning => context.l10n.uiStateStarting,
      _StatusTone.neutral => context.l10n.uiStateStarting,
    };
    return _StatusTile(
      icon: _icon(status.component),
      title: localizeConnectionComponentTitle(context.l10n, status.component),
      state: localizedState,
      tone: tone,
      detail: localizeConnectionComponentDescription(
        context.l10n,
        status.component,
      ),
      trailing: status.progress == null ? null : '${status.progress}%',
    );
  }

  IconData _icon(ConnectionComponent component) => switch (component) {
    ConnectionComponent.engine => Icons.memory_outlined,
    ConnectionComponent.localData => Icons.storage_outlined,
    ConnectionComponent.tor => Icons.hub_outlined,
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
    required this.tone,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String state;
  final String detail;
  final _StatusTone tone;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      _StatusTone.success => scheme.primary,
      _StatusTone.error => scheme.error,
      _StatusTone.warning => scheme.tertiary,
      _StatusTone.neutral => scheme.onSurfaceVariant,
    };
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
