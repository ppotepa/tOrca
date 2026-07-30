import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_controller.dart';
import '../../core/models/domain.dart';

class ConnectionCenterSheet extends ConsumerWidget {
  const ConnectionCenterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final queued = state.messages.where((message) =>
        message.state == MessageState.queued ||
        message.state == MessageState.sending).length;
    final failed = state.messages
        .where((message) => message.state == MessageState.failed)
        .length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Connection Center', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Stan lokalnego engine, sieci Tor, relaya i komunikacji P2P aktualizuje się na żywo.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              for (final step in state.startupSteps)
                _ConnectionStepTile(step: step),
              const Divider(height: 28),
              _StatusTile(
                icon: Icons.eco_outlined,
                title: 'Relay przez Tor',
                state: state.transport.phase.name,
                detail: state.transport.detail.isEmpty
                    ? state.transport.label
                    : state.transport.detail,
                trailing: state.transport.latencyMs == null
                    ? 'próba ${state.transport.retryAttempt}'
                    : '${state.transport.latencyMs} ms',
              ),
              _StatusTile(
                icon: Icons.settings_input_antenna,
                title: 'Lokalny onion P2P',
                state: state.peerServerStatus.name,
                detail: state.peerServerStatus.label,
              ),
              _StatusTile(
                icon: Icons.people_alt_outlined,
                title: 'Kontakty i sesje P2P',
                state: '${state.onlineContacts.values.where((value) => value).length}/${state.contacts.length}',
                detail: 'Aktywne obecności kontaktów i preferowane sesje bezpośrednie',
              ),
              _StatusTile(
                icon: Icons.queue_outlined,
                title: 'Kolejka wiadomości',
                state: queued == 0 && failed == 0 ? 'czysta' : '$queued oczekuje · $failed błędów',
                detail: 'Wiadomości pozostają w trwałej kolejce do czasu potwierdzenia dostawy',
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
                      final diagnostic = _diagnosticText(state);
                      await Clipboard.setData(ClipboardData(text: diagnostic));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Diagnostyka skopiowana')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Kopiuj diagnostykę'),
                  ),
                  FilledButton.icon(
                    onPressed: state.isLoading ? null : controller.retryTor,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Ponów relay'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _diagnosticText(AppState state) {
    final steps = state.startupSteps
        .map((step) => '${step.kind.name}=${step.state.name}:${step.detail}')
        .join('\n');
    return [
      'screen=${state.screen.name}',
      'transport=${state.transport.phase.name}',
      'transportLabel=${state.transport.label}',
      'transportDetail=${state.transport.detail}',
      'transportRetry=${state.transport.retryAttempt}',
      'peerServer=${state.peerServerStatus.name}',
      'contacts=${state.contacts.length}',
      'conversations=${state.conversations.length}',
      'inbox=${state.inbox.length}',
      'outbox=${state.outbox.length}',
      'error=${state.error}',
      steps,
    ].join('\n');
  }
}

class _ConnectionStepTile extends StatelessWidget {
  const _ConnectionStepTile({required this.step});

  final StartupStep step;

  @override
  Widget build(BuildContext context) => _StatusTile(
    icon: _icon(step.kind),
    title: step.title,
    state: step.state.name,
    detail: step.detail.isEmpty ? step.description : step.detail,
  );

  IconData _icon(StartupStepKind kind) => switch (kind) {
    StartupStepKind.engine => Icons.memory_outlined,
    StartupStepKind.tor => Icons.hub_outlined,
    StartupStepKind.peerListener => Icons.cell_tower_outlined,
    StartupStepKind.onionService => Icons.security_outlined,
    StartupStepKind.relay => Icons.cloud_sync_outlined,
    StartupStepKind.communication => Icons.forum_outlined,
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
    final color = normalized.contains('ready') ||
            normalized.contains('connected') ||
            normalized == 'czysta'
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
