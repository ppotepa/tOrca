import 'package:flutter/material.dart';
import '../../app/app_theme.dart';

import '../../core/models/domain.dart';

class TorStatusBar extends StatefulWidget {
  const TorStatusBar({
    super.key,
    required this.status,
    this.phase = TransportPhase.starting,
    this.desktop = false,
    this.latencyMs,
  });

  final String status;
  final TransportPhase phase;
  final bool desktop;
  final int? latencyMs;

  @override
  State<TorStatusBar> createState() => _TorStatusBarState();
}

class _TorStatusBarState extends State<TorStatusBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  bool get isConnecting => widget.phase.isConnecting;

  @override
  void initState() {
    super.initState();
    _animation.addListener(_rebuild);
    _syncAnimation();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant TorStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (isConnecting) {
      _animation.repeat();
    } else {
      _animation.stop();
      _animation.value = 0;
    }
  }

  @override
  void dispose() {
    _animation.removeListener(_rebuild);
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _phaseTone(context, widget.phase, widget.status);
    final connected = widget.phase.isConnected;
    final connecting = isConnecting;

    return Semantics(
      label: 'Status Tor: ${widget.status}',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 420),
        height: widget.desktop ? 30 : 10,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          border: Border(
            bottom: BorderSide(color: color.withValues(alpha: .40)),
          ),
        ),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 420),
                height: 3,
                decoration: BoxDecoration(
                  color: connecting ? null : color,
                  gradient: connecting
                      ? LinearGradient(
                          begin: Alignment(-1 + (_animation.value * 2), 0),
                          end: Alignment(1 + (_animation.value * 2), 0),
                          colors: [
                            color.withValues(alpha: .08),
                            color,
                            color.withValues(alpha: .08),
                          ],
                        )
                      : null,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: .45),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
            if (widget.desktop)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(Icons.eco_outlined, size: 15, color: color),
                    const SizedBox(width: 7),
                    Text(
                      widget.status.isEmpty
                          ? 'Łączenie z relayem…'
                          : widget.status,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: color.withValues(alpha: .55)),
                        ),
                      ),
                      child: Text(
                        connected && widget.latencyMs != null
                            ? '${widget.latencyMs} ms'
                            : connecting
                            ? 'reconnecting'
                            : 'offline',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: color.withValues(alpha: .92),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Color _phaseTone(BuildContext context, TransportPhase phase, String status) {
  final theme = context.statusTheme;
  final lower = status.toLowerCase();
  return phase.isConnected ||
          lower.contains('aktywny') ||
          lower.contains('połączony')
      ? theme.success
      : phase.isWarning ||
            lower.contains('ogranicz') ||
            lower.contains('degraded')
      ? theme.warning
      : phase.isError ||
            lower.contains('błąd') ||
            lower.contains('offline') ||
            lower.contains('rozłączony')
      ? theme.danger
      : theme.warning;
}
