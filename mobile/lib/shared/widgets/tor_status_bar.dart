import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/connection/connection_component.dart';
import '../../core/connection/connection_readiness.dart';
import '../../core/models/domain.dart';

/// One compact, transport-agnostic connection rail.
///
/// The three segments deliberately represent separate responsibilities: the
/// local engine, Tor/control relay, and the locally published P2P endpoint.
/// Keeping them together avoids implying that one healthy Tor connection also
/// means that inbound P2P delivery is ready.
class TransportStatusDock extends StatefulWidget {
  const TransportStatusDock({
    super.key,
    this.status = '',
    this.readiness,
    this.phase = TransportPhase.starting,
    this.peerStatus = PeerServerStatus.starting,
    this.desktop = false,
    this.latencyMs,
    this.onOpenConnectionCenter,
  });

  final String status;
  final ConnectionReadiness? readiness;
  final TransportPhase phase;
  final PeerServerStatus peerStatus;
  final bool desktop;
  final int? latencyMs;
  final VoidCallback? onOpenConnectionCenter;

  @override
  State<TransportStatusDock> createState() => _TransportStatusDockState();
}

/// Backwards-compatible name for older onboarding call sites.
typedef TorStatusBar = TransportStatusDock;

class _TransportStatusDockState extends State<TransportStatusDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathing = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  bool get _hasBusySegment =>
      widget.phase.isConnecting ||
      widget.peerStatus == PeerServerStatus.starting;

  bool get _hasErrorSegment =>
      widget.phase.isError || widget.peerStatus == PeerServerStatus.error;

  bool get _hasWarningSegment => widget.phase.isWarning;

  bool _expanded = false;

  bool get _showDetails =>
      _expanded || _hasBusySegment || _hasWarningSegment || _hasErrorSegment;

  @override
  void initState() {
    super.initState();
    _breathing.addListener(_rebuild);
    _syncAnimation();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant TransportStatusDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    _breathing.duration = Duration(
      milliseconds: _hasErrorSegment
          ? 1050
          : _hasBusySegment
          ? 1450
          : 3200,
    );
    if (_hasBusySegment ||
        _hasErrorSegment ||
        widget.phase.isConnected ||
        widget.peerStatus == PeerServerStatus.ready) {
      _breathing.repeat(reverse: true);
    } else {
      _breathing.stop();
      _breathing.value = 0;
    }
  }

  @override
  void dispose() {
    _breathing.removeListener(_rebuild);
    _breathing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    final phase = animationsDisabled ? 0.0 : _breathing.value;
    final engine = _SegmentState(
      label: 'Silnik',
      detail: _engineDetail,
      icon: Icons.memory_rounded,
      state: _engineState,
    );
    final relay = _SegmentState(
      label: 'Tor relay',
      detail: _relayDetail,
      icon: Icons.hub_outlined,
      state: _stateFromTransport(widget.phase),
    );
    final peer = _SegmentState(
      label: 'Tor P2P',
      detail: _peerDetail,
      icon: Icons.settings_input_antenna_rounded,
      state: _stateFromPeer(widget.peerStatus),
    );
    final segments = [engine, relay, peer];

    final theme = Theme.of(context);
    return Semantics(
      label:
          'Stan komunikacji: ${segments.map((segment) => '${segment.label}: ${segment.detail}').join(', ')}',
      button: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          widget.desktop ? 10 : 8,
          6,
          widget.desktop ? 10 : 8,
          4,
        ),
        child: Material(
          color: theme.colorScheme.surfaceContainerLowest,
          elevation: 5,
          shadowColor: theme.colorScheme.shadow.withValues(alpha: .28),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: theme.dividerColor.withValues(alpha: .7)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap:
                widget.onOpenConnectionCenter ??
                () => setState(() => _expanded = !_expanded),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Row(
                children: [
                  for (var index = 0; index < segments.length; index++) ...[
                    Expanded(
                      child: _ConnectionSegment(
                        segment: segments[index],
                        desktop: widget.desktop,
                        phase: phase,
                        showDetails: _showDetails,
                      ),
                    ),
                    if (index < segments.length - 1)
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        indent: 9,
                        endIndent: 9,
                        color: theme.dividerColor.withValues(alpha: .62),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  _SegmentActivity get _engineState {
    final readiness = widget.readiness;
    if (readiness != null) {
      final state = readiness.engine.state;
      return switch (state) {
        ConnectionComponentState.failed => _SegmentActivity.error,
        ConnectionComponentState.degraded => _SegmentActivity.warning,
        ConnectionComponentState.pending ||
        ConnectionComponentState.starting => _SegmentActivity.busy,
        ConnectionComponentState.ready => _SegmentActivity.ready,
      };
    }
    if (widget.phase.isError) return _SegmentActivity.error;
    if (widget.phase.isConnecting) return _SegmentActivity.busy;
    return _SegmentActivity.ready;
  }

  String get _engineDetail => switch (_engineState) {
    _SegmentActivity.ready => 'gotowy',
    _SegmentActivity.busy => 'rozgrzewanie',
    _SegmentActivity.warning => 'ograniczony',
    _SegmentActivity.error => 'wymaga uwagi',
    _SegmentActivity.idle => 'oczekuje',
  };

  String get _relayDetail =>
      widget.phase.isConnected && widget.latencyMs != null
      ? '${widget.latencyMs} ms'
      : widget.phase.isConnecting
      ? 'łączenie'
      : widget.phase.isWarning
      ? 'ograniczony'
      : widget.phase.isError
      ? 'offline'
      : 'gotowy';

  String get _peerDetail => switch (widget.peerStatus) {
    PeerServerStatus.ready => 'aktywny',
    PeerServerStatus.starting => 'uruchamianie',
    PeerServerStatus.offline => 'offline',
    PeerServerStatus.error => 'błąd',
  };
}

class _ConnectionSegment extends StatelessWidget {
  const _ConnectionSegment({
    required this.segment,
    required this.desktop,
    required this.phase,
    required this.showDetails,
  });

  final _SegmentState segment;
  final bool desktop;
  final double phase;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    final tone = _toneFor(context, segment.state);
    final breathing = switch (segment.state) {
      _SegmentActivity.busy => .13 + (.16 * phase),
      _SegmentActivity.ready => .08 + (.08 * phase),
      _SegmentActivity.warning => .09 + (.10 * phase),
      _SegmentActivity.error => .10 + (.18 * phase),
      _SegmentActivity.idle => .03,
    };
    final glow = switch (segment.state) {
      _SegmentActivity.busy => 5 + (10 * phase),
      _SegmentActivity.ready => 3 + (7 * phase),
      _SegmentActivity.warning => 3 + (8 * phase),
      _SegmentActivity.error => 4 + (10 * phase),
      _SegmentActivity.idle => 0.0,
    };
    final isBusy = segment.state == _SegmentActivity.busy;

    return Semantics(
      label: '${segment.label}: ${segment.detail}',
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: desktop ? 12 : 10,
          vertical: showDetails ? 8 : 6,
        ),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      tone.withValues(alpha: breathing),
                      tone.withValues(alpha: breathing * .26),
                    ],
                  ),
                  boxShadow: glow == 0
                      ? null
                      : [
                          BoxShadow(
                            color: tone.withValues(alpha: breathing * .72),
                            blurRadius: glow,
                            spreadRadius: .15,
                          ),
                        ],
                ),
              ),
            ),
            Row(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    if (isBusy)
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.7,
                          valueColor: AlwaysStoppedAnimation<Color>(tone),
                        ),
                      ),
                    Icon(segment.icon, size: 16, color: tone),
                  ],
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        segment.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tone,
                          fontSize: desktop ? 11 : 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (showDetails) ...[
                        const SizedBox(height: 1),
                        Text(
                          segment.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tone.withValues(alpha: .82),
                            fontSize: desktop ? 10 : 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(height: 2, color: tone.withValues(alpha: .72)),
            ),
          ],
        ),
      ),
    );
  }
}

enum _SegmentActivity { idle, busy, ready, warning, error }

class _SegmentState {
  const _SegmentState({
    required this.label,
    required this.detail,
    required this.icon,
    required this.state,
  });

  final String label;
  final String detail;
  final IconData icon;
  final _SegmentActivity state;
}

_SegmentActivity _stateFromTransport(TransportPhase phase) => switch (phase) {
  TransportPhase.connected => _SegmentActivity.ready,
  TransportPhase.degraded => _SegmentActivity.warning,
  TransportPhase.offline || TransportPhase.error => _SegmentActivity.error,
  TransportPhase.starting ||
  TransportPhase.bootstrapping ||
  TransportPhase.connecting ||
  TransportPhase.reconnecting => _SegmentActivity.busy,
};

_SegmentActivity _stateFromPeer(PeerServerStatus status) => switch (status) {
  PeerServerStatus.ready => _SegmentActivity.ready,
  PeerServerStatus.starting => _SegmentActivity.busy,
  PeerServerStatus.offline => _SegmentActivity.idle,
  PeerServerStatus.error => _SegmentActivity.error,
};

Color _toneFor(BuildContext context, _SegmentActivity state) {
  final theme = context.statusTheme;
  return switch (state) {
    _SegmentActivity.ready => theme.success,
    _SegmentActivity.warning || _SegmentActivity.busy => theme.warning,
    _SegmentActivity.error => theme.danger,
    _SegmentActivity.idle => Theme.of(context).colorScheme.outline,
  };
}
