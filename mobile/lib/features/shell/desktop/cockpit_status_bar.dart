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
    return Material(
      color: shell.surface,
      child: Semantics(
        button: true,
        label: 'Centrum połączenia TorChat',
        hint: 'Otwiera szczegóły połączenia i diagnostykę transportu',
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
                Text('TorChat', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                const CockpitIndicator(
                  label: 'ENGINE',
                  state: CockpitIndicatorState.ready,
                  detail: 'Lokalny engine i baza są gotowe',
                ),
                const SizedBox(width: 10),
                CockpitIndicator(
                  label: 'TOR RELAY',
                  state: cockpitRelayState(phase),
                  detail: latencyMs == null
                      ? 'Połączenie z relayem przez Tor'
                      : 'Połączenie z relayem · $latencyMs ms',
                ),
                const SizedBox(width: 10),
                CockpitIndicator(
                  label: 'TOR P2P',
                  state: cockpitP2pState(peerServerStatus),
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
      ),
    );
  }
}

class CompactCockpitStatusBar extends StatelessWidget {
  const CompactCockpitStatusBar({
    super.key,
    required this.phase,
    required this.peerServerStatus,
    required this.onOpenConnectionCenter,
    this.latencyMs,
  });

  final TransportPhase phase;
  final PeerServerStatus peerServerStatus;
  final int? latencyMs;
  final VoidCallback onOpenConnectionCenter;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    return Material(
      color: shell.surface,
      child: Semantics(
        button: true,
        label: 'Centrum połączenia TorChat',
        hint: 'Otwiera szczegóły połączenia i diagnostykę transportu',
        child: InkWell(
          onTap: onOpenConnectionCenter,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: shell.border,
                  width: shell.borderWidth,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CockpitIndicator(
                  label: 'ENG',
                  state: CockpitIndicatorState.ready,
                  detail: 'Engine gotowy',
                  compact: true,
                ),
                const SizedBox(width: 6),
                CockpitIndicator(
                  label: 'RELAY',
                  state: cockpitRelayState(phase),
                  detail: latencyMs == null
                      ? phase.label
                      : '${phase.label} · $latencyMs ms',
                  compact: true,
                ),
                const SizedBox(width: 6),
                CockpitIndicator(
                  label: 'P2P',
                  state: cockpitP2pState(peerServerStatus),
                  detail: peerServerStatus.label,
                  compact: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

CockpitIndicatorState cockpitRelayState(TransportPhase phase) => phase.isError
    ? CockpitIndicatorState.error
    : phase == TransportPhase.connected
        ? CockpitIndicatorState.ready
        : CockpitIndicatorState.transitioning;

CockpitIndicatorState cockpitP2pState(PeerServerStatus status) => switch (status) {
      PeerServerStatus.ready => CockpitIndicatorState.ready,
      PeerServerStatus.starting => CockpitIndicatorState.transitioning,
      PeerServerStatus.offline => CockpitIndicatorState.inactive,
      PeerServerStatus.error => CockpitIndicatorState.error,
    };

enum CockpitIndicatorState { ready, transitioning, inactive, error }

class CockpitIndicator extends StatefulWidget {
  const CockpitIndicator({
    super.key,
    required this.label,
    required this.state,
    required this.detail,
    this.compact = false,
  });

  final String label;
  final CockpitIndicatorState state;
  final String detail;
  final bool compact;

  @override
  State<CockpitIndicator> createState() => _CockpitIndicatorState();
}

class _CockpitIndicatorState extends State<CockpitIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  bool _systemReducedMotion = false;

  bool get _reduceMotion =>
      _systemReducedMotion || TorChatMotionPolicy.enabled;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: .35,
      upperBound: 1,
    );
    TorChatMotionPolicy.reducedMotion.addListener(_syncAnimation);
    _syncAnimation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_systemReducedMotion != reduced) {
      _systemReducedMotion = reduced;
      _syncAnimation();
    }
  }

  @override
  void didUpdateWidget(covariant CockpitIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _syncAnimation();
  }

  void _syncAnimation() {
    if (!mounted) return;
    if (widget.state == CockpitIndicatorState.transitioning && !_reduceMotion) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    TorChatMotionPolicy.reducedMotion.removeListener(_syncAnimation);
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
    final semanticState = switch (widget.state) {
      CockpitIndicatorState.ready => 'gotowy',
      CockpitIndicatorState.transitioning => 'łączenie',
      CockpitIndicatorState.inactive => 'nieaktywny',
      CockpitIndicatorState.error => 'błąd',
    };

    return Semantics(
      label: '${widget.label}: $semanticState. ${widget.detail}',
      liveRegion: widget.state == CockpitIndicatorState.error ||
          widget.state == CockpitIndicatorState.transitioning,
      child: ExcludeSemantics(
        child: Tooltip(
          message: '${widget.label}\n${widget.detail}',
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 7 : 10,
              vertical: widget.compact ? 3 : 5,
            ),
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
                    opacity: _reduceMotion ? 1 : _pulse.value,
                    child: Container(
                      width: widget.compact ? 6 : 8,
                      height: widget.compact ? 6 : 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        boxShadow: context.effectsTheme.pixelated
                            ? null
                            : [
                                BoxShadow(
                                  color: color.withValues(alpha: .45),
                                  blurRadius: widget.compact ? 5 : 8,
                                ),
                              ],
                      ),
                    ),
                  ),
                ),
                SizedBox(width: widget.compact ? 5 : 7),
                Text(
                  widget.label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: widget.compact ? 9 : null,
                        letterSpacing: widget.compact ? .3 : .7,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
