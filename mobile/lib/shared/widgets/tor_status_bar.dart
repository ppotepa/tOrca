import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/connection/connection_readiness.dart';
import '../../core/models/domain.dart';
import 'status_probe.dart';

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
    this.transportStatuses = const {},
    this.probeRegistry = StatusProbeRegistry.standard,
    this.phase = TransportPhase.starting,
    this.peerStatus = PeerServerStatus.starting,
    this.desktop = false,
    this.embeddedInHeader = false,
    this.latencyMs,
    this.onOpenConnectionCenter,
  });

  final String status;
  final ConnectionReadiness? readiness;
  final Map<TransportComponent, TransportStatusSnapshot> transportStatuses;
  final StatusProbeRegistry probeRegistry;
  final TransportPhase phase;
  final PeerServerStatus peerStatus;
  final bool desktop;
  final bool embeddedInHeader;
  final int? latencyMs;
  final VoidCallback? onOpenConnectionCenter;

  @override
  State<TransportStatusDock> createState() => _TransportStatusDockState();
}

class _TransportStatusDockState extends State<TransportStatusDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathing = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  bool get _hasBusySegment => widget.probeRegistry
      .read(_diagnostics)
      .any((probe) => probe.state == StatusProbeState.starting);

  bool get _hasErrorSegment => widget.probeRegistry
      .read(_diagnostics)
      .any((probe) => probe.state == StatusProbeState.error);

  bool get _hasWarningSegment => widget.probeRegistry
      .read(_diagnostics)
      .any((probe) => probe.state == StatusProbeState.degraded);

  TransportDiagnosticsSnapshot get _diagnostics => TransportDiagnosticsSnapshot(
    phase: widget.phase,
    peerStatus: widget.peerStatus,
    readiness: widget.readiness,
    statuses: widget.transportStatuses,
    latencyMs: widget.latencyMs,
  );

  bool _expanded = false;

  // The header dock stays compact even while a probe is busy or degraded.
  // Busy state is communicated by the spinner/glow; verbose diagnostics are
  // opt-in via tap so the status rail never becomes a full-screen panel.
  // A dock embedded in an AppBar must never grow horizontally. Detailed
  // diagnostics belong to the connection center, not to the title row.
  bool get _showDetails => !widget.embeddedInHeader && _expanded;

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
    if (_hasBusySegment || _hasErrorSegment || _hasWarningSegment) {
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
    final segments = widget.probeRegistry
        .read(_diagnostics)
        .map(_segmentFromProbe)
        .toList(growable: false);

    final theme = Theme.of(context);
    final embedded = widget.embeddedInHeader;
    final dock = Material(
      color: theme.colorScheme.surfaceContainerLowest,
      elevation: embedded ? 4 : 10,
      shadowColor: theme.colorScheme.shadow.withValues(
        alpha: embedded ? .28 : .38,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(embedded ? 11 : 14),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: .78)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap:
            widget.onOpenConnectionCenter ??
            () => setState(() => _expanded = !_expanded),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: _showDetails ? 5 : (embedded ? 2 : 3),
              vertical: _showDetails ? 4 : (embedded ? 2 : 3),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < segments.length; index++) ...[
                  SizedBox(
                    width: _showDetails
                        ? (widget.desktop ? 112 : 96)
                        : (embedded ? 27 : 28),
                    child: _ConnectionSegment(
                      segment: segments[index],
                      desktop: widget.desktop,
                      phase: phase,
                      showDetails: _showDetails,
                    ),
                  ),
                  if (index < segments.length - 1)
                    SizedBox(
                      height: _showDetails ? 32 : (embedded ? 20 : 22),
                      child: VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: theme.dividerColor.withValues(alpha: .62),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return RepaintBoundary(
      child: Semantics(
        label:
            'Stan komunikacji: ${segments.map((segment) => '${segment.label}: ${segment.detail}').join(', ')}',
        button: true,
        child: Align(
          alignment: embedded ? Alignment.center : Alignment.topCenter,
          child: Padding(
            padding: embedded
                ? EdgeInsets.zero
                : const EdgeInsets.only(top: 4, bottom: 6),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                // The header indicator is deliberately a floating island,
                // never a row that consumes the whole application width.
                maxWidth: embedded
                    ? (_showDetails ? 300 : 132)
                    : (widget.desktop ? 360 : 300),
                minWidth: _showDetails ? 220 : 96,
              ),
              child: dock,
            ),
          ),
        ),
      ),
    );
  }

  _SegmentState _segmentFromProbe(StatusProbeSnapshot probe) => _SegmentState(
    label: probe.label,
    detail: probe.latencyMs == null
        ? probe.detail
        : '${probe.detail} · ${probe.latencyMs} ms',
    icon: probe.icon,
    state: switch (probe.state) {
      StatusProbeState.idle => _SegmentActivity.idle,
      StatusProbeState.starting => _SegmentActivity.busy,
      StatusProbeState.ready => _SegmentActivity.ready,
      StatusProbeState.degraded => _SegmentActivity.warning,
      StatusProbeState.error ||
      StatusProbeState.offline => _SegmentActivity.error,
    },
  );
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
          // Compact cells are intentionally icon-only. Keep their internal
          // inset smaller than the cell width so a busy spinner never forces
          // a RenderFlex overflow on narrow/mobile layouts.
          horizontal: showDetails ? (desktop ? 12 : 10) : 2,
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
              mainAxisSize: showDetails ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: showDetails
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
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
                if (showDetails) ...[
                  const SizedBox(width: 7),
                  Flexible(
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
                    ),
                  ),
                ],
              ],
            ),
            if (showDetails)
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

Color _toneFor(BuildContext context, _SegmentActivity state) {
  final theme = context.statusTheme;
  return switch (state) {
    _SegmentActivity.ready => theme.success,
    _SegmentActivity.warning || _SegmentActivity.busy => theme.warning,
    _SegmentActivity.error => theme.danger,
    _SegmentActivity.idle => Theme.of(context).colorScheme.outline,
  };
}
