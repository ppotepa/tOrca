import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/connection/connection_component.dart';
import '../../core/connection/connection_readiness.dart';
import '../../core/connection/connection_summary.dart';
import '../../shared/widgets/tor_status_bar.dart';
import '../../locales/presentation/app_localizations_x.dart';
import '../../locales/presentation/status_localizer.dart';

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
    final l10n = context.l10n;
    final statuses = [...connection.components];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ConnectionStatusLamp(
              phase: summary.phase,
              peerStatus: summary.peerServerStatus,
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
                              l10n.warmupTitle,
                              style: Theme.of(context).textTheme.headlineMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.warmupSubtitle,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              localizeTransportPhase(l10n, summary.phase),
                              style: Theme.of(context).textTheme.titleSmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.uiConnectionSummaryDetail,
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            for (
                              var index = 0;
                              index < statuses.length;
                              index += 1
                            )
                              _WarmupRow(
                                status: statuses[index],
                                title: index == statuses.length - 1
                                    ? l10n.communicationReady
                                    : localizeConnectionComponentTitle(
                                        l10n,
                                        statuses[index].component,
                                      ),
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
                                label: Text(l10n.retry),
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
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  localizeConnectionComponentDescription(
                    context.l10n,
                    status.component,
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (status.progress case final progress?) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: progress / 100),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}