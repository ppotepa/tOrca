import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/connection/connection_component.dart';
import '../../core/connection/connection_readiness.dart';
import '../../core/models/domain.dart';
import '../../locales/presentation/app_localizations_x.dart';

/// Compact transport indicator. The left dot is Tor/SOCKS; the right dot is
/// the local P2P/onion path. Detailed diagnostics remain behind the tap.
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

  _LampState get _fallbackState => switch (widget.phase) {
    TransportPhase.connected => _LampState.ready,
    TransportPhase.degraded ||
    TransportPhase.reconnecting => _LampState.degraded,
    TransportPhase.error || TransportPhase.offline => _LampState.error,
    _ => _LampState.starting,
  };

  _LampState _state(ConnectionComponentStatus? status) =>
      switch (status?.state) {
        ConnectionComponentState.ready => _LampState.ready,
        ConnectionComponentState.degraded => _LampState.degraded,
        ConnectionComponentState.failed => _LampState.error,
        _ => _LampState.starting,
      };

  _LampState get _torState =>
      widget.readiness == null ? _fallbackState : _state(widget.readiness!.tor);

  _LampState get _p2pState {
    final readiness = widget.readiness;
    if (readiness == null) return _fallbackState;
    if (readiness.peerListener.state == ConnectionComponentState.failed ||
        readiness.onionService.state == ConnectionComponentState.failed) {
      return _LampState.error;
    }
    if (readiness.peerListener.state == ConnectionComponentState.degraded ||
        readiness.onionService.state == ConnectionComponentState.degraded) {
      return _LampState.degraded;
    }
    if (readiness.peerListener.ready && readiness.onionService.ready) {
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
    final tor = _torState;
    final p2p = _p2pState;
    final label = 'Tor: ${_lampLabel(context, tor)} · P2P: ${_lampLabel(context, p2p)}';
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    final size = widget.embeddedInHeader ? 42.0 : 52.0;
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
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => CustomPaint(
                size: Size(size, widget.embeddedInHeader ? 18 : 22),
                painter: _DualLampPainter(
                  tor: tor,
                  p2p: p2p,
                  readyColor: context.statusTheme.success,
                  warningColor: context.statusTheme.warning,
                  errorColor: context.statusTheme.danger,
                  phase: animationsDisabled ? 0 : _controller.value,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _LampState { starting, ready, degraded, error }

String _lampLabel(BuildContext context, _LampState state) => switch (state) {
  _LampState.ready => context.l10n.uiStatusReady,
  _LampState.starting => context.l10n.uiStatusStarting,
  _LampState.degraded => context.l10n.uiStatusRetrying,
  _LampState.error => context.l10n.uiStatusError,
};

class _DualLampPainter extends CustomPainter {
  const _DualLampPainter({
    required this.tor,
    required this.p2p,
    required this.readyColor,
    required this.warningColor,
    required this.errorColor,
    required this.phase,
  });

  final _LampState tor;
  final _LampState p2p;
  final Color readyColor;
  final Color warningColor;
  final Color errorColor;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    _paintDot(canvas, Offset(size.width * .25, size.height / 2), tor);
    _paintDot(canvas, Offset(size.width * .75, size.height / 2), p2p);
  }

  void _paintDot(Canvas canvas, Offset center, _LampState state) {
    final color = switch (state) {
      _LampState.ready => readyColor,
      _LampState.starting || _LampState.degraded => warningColor,
      _LampState.error => errorColor,
    };
    final intensity = switch (state) {
      _LampState.ready => .82,
      _LampState.starting => .35 + (.55 * (1 - (2 * phase - 1).abs())),
      _LampState.degraded => phase < .2 ? .95 : .18,
      _LampState.error => phase < .1 || (phase > .25 && phase < .4) ? .95 : .14,
    };
    const radius = 8.0;
    canvas.drawCircle(
      center,
      radius * .78,
      Paint()
        ..color = color.withValues(alpha: intensity * .35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(
      center,
      radius * .54,
      Paint()..color = color.withValues(alpha: intensity),
    );
    canvas.drawCircle(
      center,
      radius * .72,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: .9),
    );
  }

  @override
  bool shouldRepaint(covariant _DualLampPainter oldDelegate) =>
      oldDelegate.tor != tor ||
      oldDelegate.p2p != p2p ||
      oldDelegate.phase != phase;
}
