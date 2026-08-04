import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/connection/connection_readiness.dart';
import '../../core/models/domain.dart';
import '../../app/app_theme.dart';

/// Compact, single-lamp status indicator for the application header.
/// Detailed component diagnostics remain available through the tap action.
class ConnectionStatusLamp extends StatefulWidget {
  const ConnectionStatusLamp({
    super.key,
    this.readiness,
    this.phase = TransportPhase.starting,
    this.peerStatus = PeerServerStatus.starting,
    this.embeddedInHeader = false,
    this.desktop = false,
    this.onOpenConnectionCenter,
  });

  final ConnectionReadiness? readiness;
  final TransportPhase phase;
  final PeerServerStatus peerStatus;
  final bool embeddedInHeader;
  final bool desktop;
  final VoidCallback? onOpenConnectionCenter;

  @override
  State<ConnectionStatusLamp> createState() => _ConnectionStatusLampState();
}

class _ConnectionStatusLampState extends State<ConnectionStatusLamp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  _LampState get _state {
    final readiness = widget.readiness;
    if (readiness?.failed == true || widget.phase == TransportPhase.error) {
      return _LampState.error;
    }
    if (readiness?.degraded == true ||
        widget.phase == TransportPhase.degraded ||
        widget.peerStatus == PeerServerStatus.offline) {
      return _LampState.degraded;
    }
    if (readiness?.communicationReady == true ||
        widget.phase == TransportPhase.connected) {
      return _LampState.ready;
    }
    return _LampState.starting;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final tone = switch (state) {
      _LampState.ready => context.statusTheme.success,
      _LampState.starting || _LampState.degraded => context.statusTheme.warning,
      _LampState.error => context.statusTheme.danger,
    };
    final label = switch (state) {
      _LampState.ready => 'Gotowe: Tor i P2P są dostępne',
      _LampState.starting => 'Uruchamianie komunikacji',
      _LampState.degraded => 'Komunikacja działa częściowo lub ponawia próbę',
      _LampState.error => 'Błąd komunikacji',
    };
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    final child = AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.embeddedInHeader ? 18 : 22),
        painter: _LampPainter(
          color: tone,
          state: state,
          phase: animationsDisabled ? 0 : _controller.value,
        ),
      ),
    );

    return Semantics(
      button: widget.onOpenConnectionCenter != null,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: widget.onOpenConnectionCenter,
          radius: widget.embeddedInHeader ? 20 : 24,
          child: Padding(
            padding: EdgeInsets.all(widget.embeddedInHeader ? 5 : 7),
            child: child,
          ),
        ),
      ),
    );
  }
}

enum _LampState { starting, ready, degraded, error }

class _LampPainter extends CustomPainter {
  const _LampPainter({required this.color, required this.state, required this.phase});

  final Color color;
  final _LampState state;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final intensity = switch (state) {
      _LampState.ready => .82,
      _LampState.starting => .35 + (.55 * (1 - (2 * phase - 1).abs())),
      _LampState.degraded => phase < .12 || (phase > .22 && phase < .34) ? .95 : .18,
      _LampState.error => phase < .08 || (phase > .14 && phase < .22) || (phase > .28 && phase < .36) ? .95 : .14,
    };
    final glow = Paint()
      ..color = color.withValues(alpha: intensity * .35)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * .65);
    canvas.drawCircle(center, radius * .78, glow);
    final fill = Paint()..color = color.withValues(alpha: intensity);
    canvas.drawCircle(center, radius * .54, fill);
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: .9);
    canvas.drawCircle(center, radius * .72, border);
  }

  @override
  bool shouldRepaint(covariant _LampPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.state != state || oldDelegate.phase != phase;
}
