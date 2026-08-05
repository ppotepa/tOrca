import 'package:flutter/material.dart';

import 'package:torchat_flutter_ui/app_theme.dart';
import 'package:torchat_flutter_ui/core/models/domain.dart';
import '../../shared/widgets/tor_status_bar.dart';
import '../../locales/presentation/app_localizations_x.dart';
import '../../locales/presentation/status_localizer.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThemedIcon(
            Icons.eco,
            size: 72,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.appTitle,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(context.l10n.appTagline),
        ],
      ),
    ),
  );
}

class BootScreen extends StatelessWidget {
  const BootScreen({
    super.key,
    required this.phase,
    this.status = '',
    this.detail = '',
    required this.error,
    required this.retry,
    this.connecting = false,
    required this.steps,
  });
  final TransportPhase phase;
  @Deprecated('Status copy is localized from phase in the presentation layer.')
  final String status;
  @Deprecated('Technical details are not presented on the boot screen.')
  final String detail;
  final String error;
  final VoidCallback retry;
  @Deprecated('Progress is derived from startup steps.')
  final bool connecting;
  final List<StartupStep> steps;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 56),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ThemedIcon(
                      Icons.eco,
                      size: 72,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.appTitle,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(context.l10n.appTagline),
                    const SizedBox(height: 30),
                    Text(
                      localizeTransportPhase(context.l10n, phase),
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    StartupTimeline(steps: steps),
                    if (error.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(
                        error,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.statusTheme.danger),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: retry,
                        icon: const ThemedIcon(Icons.refresh),
                        label: Text(context.l10n.commonRetry),
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
  );
}

class StartupTimeline extends StatelessWidget {
  const StartupTimeline({super.key, required this.steps});

  final List<StartupStep> steps;

  @override
  Widget build(BuildContext context) {
    final visible = steps.isEmpty ? initialStartupSteps() : steps;
    return Column(
      children: [
        for (var index = 0; index < visible.length; index += 1)
          _StartupTimelineRow(
            step: visible[index],
            last: index == visible.length - 1,
          ),
      ],
    );
  }
}

class _StartupTimelineRow extends StatefulWidget {
  const _StartupTimelineRow({required this.step, required this.last});

  final StartupStep step;
  final bool last;

  @override
  State<_StartupTimelineRow> createState() => _StartupTimelineRowState();
}

class _StartupTimelineRowState extends State<_StartupTimelineRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool get busy => widget.step.state == StartupStepState.running;

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _StartupTimelineRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    if (busy) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final theme = context.statusTheme;
    final color = switch (step.state) {
      StartupStepState.pending => Theme.of(context).colorScheme.outline,
      StartupStepState.running => theme.warning,
      StartupStepState.ready => theme.success,
      StartupStepState.warning => theme.warning,
      StartupStepState.error => theme.danger,
      StartupStepState.blocked => Theme.of(
        context,
      ).colorScheme.onSurfaceVariant.withValues(alpha: .55),
    };
    final icon = switch (step.state) {
      StartupStepState.pending => Icons.circle_outlined,
      StartupStepState.running => Icons.more_horiz,
      StartupStepState.ready => Icons.check,
      StartupStepState.warning => Icons.priority_high,
      StartupStepState.error => Icons.close,
      StartupStepState.blocked => Icons.remove,
    };
    return IntrinsicHeight(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.last ? 58 : 68),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, child) => Transform.scale(
                      scale: busy ? .92 + (_pulse.value * .12) : 1,
                      child: Opacity(
                        opacity: busy ? .55 + (_pulse.value * .45) : 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: busy
                                ? [
                                    BoxShadow(
                                      color: color.withValues(
                                        alpha: .12 + (_pulse.value * .28),
                                      ),
                                      blurRadius: 5 + (_pulse.value * 9),
                                      spreadRadius: _pulse.value * 2,
                                    ),
                                  ]
                                : const [],
                          ),
                          child: child,
                        ),
                      ),
                    ),
                    child: AnimatedContainer(
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
                  ),
                  if (!widget.last)
                    Expanded(
                      child: Container(
                        width: 1,
                        color:
                            (step.state == StartupStepState.ready
                                    ? theme.success
                                    : Theme.of(context).colorScheme.outline)
                                .withValues(alpha: .42),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      localizeStartupStepTitle(context.l10n, step.kind),
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      localizeStartupStepDescription(context.l10n, step.kind),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TorScreen extends StatelessWidget {
  const TorScreen({
    super.key,
    this.phase = TransportPhase.starting,
    this.status = '',
    this.detail = '',
    required this.progress,
    required this.error,
    required this.retry,
    required this.connecting,
  });
  final TransportPhase phase;
  @Deprecated('Status copy is localized from phase in the presentation layer.')
  final String status;
  @Deprecated('Technical details are not presented on the Tor screen.')
  final String detail;
  final int? progress;
  final String error;
  final VoidCallback retry;
  final bool connecting;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemedIcon(
                Icons.eco,
                size: 64,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              const SizedBox(height: 18),
              Text(
                localizeTransportPhase(context.l10n, phase),
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              if (progress != null) ...[
                const SizedBox(height: 18),
                LinearProgressIndicator(value: progress! / 100),
                const SizedBox(height: 8),
                Text('$progress%'),
              ],
              if (error.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.statusTheme.danger),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: retry,
                  child: Text(context.l10n.commonRetry),
                ),
              ],
              if (error.isEmpty && connecting)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: CircularProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class NicknameScreen extends StatelessWidget {
  const NicknameScreen({
    super.key,
    required this.controller,
    required this.transport,
    required this.ready,
    required this.error,
    required this.onSave,
  });
  final TextEditingController controller;
  final String error;
  final RuntimeTorStatus transport;
  final bool ready;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          ConnectionStatusLamp(
            phase: transport.phase,
            desktop: true,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ThemedIcon(
                    Icons.person_outline,
                    size: 56,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    context.l10n.nicknameLabel,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ready
                        ? context.l10n.nicknameDescription
                        : context.l10n.warmupSubtitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    onSubmitted: (_) {
                      if (ready) onSave();
                    },
                    decoration: InputDecoration(
                      labelText: context.l10n.onboardingNicknameLabel,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        error,
                        style: TextStyle(color: context.statusTheme.danger),
                      ),
                    ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: ready ? onSave : null,
                    child: Text(context.l10n.onboardingSaveNickname),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
