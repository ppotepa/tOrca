import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../core/models/domain.dart';

class CockpitStatusBar extends StatelessWidget {
  const CockpitStatusBar({
    super.key,
    required this.phase,
    required this.peerServerStatus,
    required this.nickname,
    required this.onOpenConnectionCenter,
    required this.onOpenSettings,
    this.latencyMs,
  });

  final TransportPhase phase;
  final PeerServerStatus peerServerStatus;
  final String nickname;
  final int? latencyMs;
  final VoidCallback onOpenConnectionCenter;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final relayState = phase.isError
        ? CockpitIndicatorState.error
        : phase == TransportPhase.connected
            ? CockpitIndicatorState.ready
            : CockpitIndicatorState.transitioning;
    final p2pState = switch (peerServerStatus) {
      PeerServerStatus.ready => CockpitIndicatorState.ready,
      PeerServerStatus.starting => CockpitIndicatorState.transitioning,
      PeerServerStatus.offline => CockpitIndicatorState.inactive,
      PeerServerStatus.error => CockpitIndicatorState.error,
    };

    return Material(
      color: shell.surface,
      child: InkWell(
        onTap: onOpenConnectionCenter,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: shell.border,
                width: shell.borderWidth,
              ),
            ),
          ),
          child: Row(
            children: [
              const ThemedIcon(Icons.shield_outlined, size: 18),
              const SizedBox(width: 8),
              Text(
                'TorChat',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              const CockpitIndicator(
                label: 'ENGINE',
                state: CockpitIndicatorState.ready,
                detail: 'Lokalny engine i baza są gotowe',
              ),
              const SizedBox(width: 10),
              CockpitIndicator(
                label: 'TOR RELAY',
                state: relayState,
                detail: latencyMs == null
                    ? 'Połączenie z relayem przez Tor'
                    : 'Połączenie z relayem · ${latencyMs} ms',
              ),
              const SizedBox(width: 10),
              CockpitIndicator(
                label: 'TOR P2P',
                state: p2pState,
                detail: peerServerStatus.label,
              ),
              const Spacer(),
              if (nickname.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '@$nickname',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              IconButton(
                tooltip: 'Ustawienia',
                onPressed: onOpenSettings,
                icon: const ThemedIcon(Icons.settings_outlined, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum CockpitIndicatorState { ready, transitioning, inactive, error }

class CockpitIndicator extends StatefulWidget {
  const CockpitIndicator({
    super.key,
    required this.label,
    required this.state,
    required this.detail,
  });

  final String label;
  final CockpitIndicatorState state;
  final String detail;

  @override
  State<CockpitIndicator> createState() => _CockpitIndicatorState();
}

class _CockpitIndicatorState extends State<CockpitIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: .35,
      upperBound: 1,
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant CockpitIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.state == CockpitIndicatorState.transitioning) {
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
    final status = context.statusTheme;
    final shell = context.shellTheme;
    final color = switch (widget.state) {
      CockpitIndicatorState.ready => status.success,
      CockpitIndicatorState.transitioning => status.warning,
      CockpitIndicatorState.inactive => status.offline,
      CockpitIndicatorState.error => status.danger,
    };
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Tooltip(
      message: '${widget.label}\n${widget.detail}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: shell.raisedSurface,
          border: Border.all(color: shell.border, width: shell.borderWidth),
          borderRadius: context.effectsTheme.pixelated
              ? BorderRadius.zero
              : BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => Opacity(
                opacity: reduceMotion ? 1 : _pulse.value,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: context.effectsTheme.pixelated
                        ? null
                        : [
                            BoxShadow(
                              color: color.withValues(alpha: .45),
                              blurRadius: 8,
                            ),
                          ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 7),
            Text(
              widget.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: .7,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
