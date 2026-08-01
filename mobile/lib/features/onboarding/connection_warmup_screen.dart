import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/connection/connection_component.dart';
import '../../core/connection/connection_readiness.dart';
import '../../core/connection/connection_summary.dart';
import '../../shared/widgets/tor_status_bar.dart';

class ConnectionWarmupScreen extends StatelessWidget {
  const ConnectionWarmupScreen({
    super.key,
    required this.connection,
    required this.summary,
    required this.error,
    required this.retry,
  });

  final ConnectionReadiness connection;
  final ConnectionSummary summary;
  final String error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final statuses = [
      ...connection.components,
      ConnectionComponentStatus(
        component: ConnectionComponent.relay,
        state: connection.communicationReady
            ? ConnectionComponentState.ready
            : connection.failed
            ? ConnectionComponentState.failed
            : connection.degraded
            ? ConnectionComponentState.degraded
            : ConnectionComponentState.starting,
        detail: connection.communicationReady
            ? 'TorChat jest gotowy do komunikacji'
            : connection.startupSteps.last.detail,
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TransportStatusDock(
              phase: summary.phase,
              peerStatus: summary.peerServerStatus,
              latencyMs: summary.latencyMs,
              readiness: connection,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 56,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ThemedIcon(
                              Icons.eco,
                              size: 72,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Rozgrzewanie TorChat',
                              style: Theme.of(context).textTheme.headlineMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Prywatne wiadomości przez Tor',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              summary.status,
                              style: Theme.of(context).textTheme.titleSmall,
                              textAlign: TextAlign.center,
                            ),
                            if (summary.detail.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                summary.detail,
                                style: Theme.of(context).textTheme.bodySmall,
                                textAlign: TextAlign.center,
                              ),
                            ],
                            const SizedBox(height: 24),
                            for (
                              var index = 0;
                              index < statuses.length;
                              index += 1
                            )
                              _WarmupRow(
                                status: statuses[index],
                                title: index == statuses.length - 1
                                    ? 'Gotowość komunikacji'
                                    : statuses[index].component.title,
                                last: index == statuses.length - 1,
                              ),
                            if (error.isNotEmpty) ...[
                              const SizedBox(height: 18),
                              Text(
                                error,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: context.statusTheme.danger,
                                ),
                              ),
                            ],
                            if (connection.failed || error.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: retry,
                                icon: const ThemedIcon(Icons.refresh),
                                label: const Text('Spróbuj ponownie'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WarmupRow extends StatelessWidget {
  const _WarmupRow({
    required this.status,
    required this.title,
    required this.last,
  });

  final ConnectionComponentStatus status;
  final String title;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = context.statusTheme;
    final color = switch (status.state) {
      ConnectionComponentState.pending => Theme.of(context).colorScheme.outline,
      ConnectionComponentState.starting => theme.warning,
      ConnectionComponentState.ready => theme.success,
      ConnectionComponentState.degraded => theme.warning,
      ConnectionComponentState.failed => theme.danger,
    };
    final icon = switch (status.state) {
      ConnectionComponentState.pending => Icons.circle_outlined,
      ConnectionComponentState.starting => Icons.more_horiz,
      ConnectionComponentState.ready => Icons.check,
      ConnectionComponentState.degraded => Icons.priority_high,
      ConnectionComponentState.failed => Icons.close,
    };

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .16),
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: .75)),
                  ),
                  child: Icon(icon, size: 14, color: color),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 1,
                      color: color.withValues(alpha: .35),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status.detail.isEmpty
                        ? status.component.description
                        : status.detail,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (status.progress case final progress?) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: progress / 100),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
