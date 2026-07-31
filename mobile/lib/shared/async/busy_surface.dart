import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/extensions/torchat_activity_theme.dart';
import 'async_operation_state.dart';
import 'themed_activity_indicator.dart';

enum BusyPresentation { overlay, replace, inline }

class BusySurface extends StatefulWidget {
  const BusySurface({
    super.key,
    required this.state,
    required this.child,
    this.presentation = BusyPresentation.overlay,
    this.label = '',
    this.blockInput = true,
    this.minHeight = 96,
    this.showDelay = const Duration(milliseconds: 150),
    this.minimumVisibleDuration = const Duration(milliseconds: 300),
  });

  final AsyncOperationState state;
  final Widget child;
  final BusyPresentation presentation;
  final String label;
  final bool blockInput;
  final double minHeight;
  final Duration showDelay;
  final Duration minimumVisibleDuration;

  @override
  State<BusySurface> createState() => _BusySurfaceState();
}

class _BusySurfaceState extends State<BusySurface> {
  Timer? _showTimer;
  Timer? _hideTimer;
  DateTime? _shownAt;
  bool _indicatorVisible = false;

  @override
  void initState() {
    super.initState();
    _synchronize(widget.state.busy);
  }

  @override
  void didUpdateWidget(covariant BusySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.busy != widget.state.busy) {
      _synchronize(widget.state.busy);
    }
  }

  void _synchronize(bool busy) {
    if (busy) {
      _hideTimer?.cancel();
      _hideTimer = null;
      if (_indicatorVisible || _showTimer != null) return;
      _showTimer = Timer(widget.showDelay, () {
        _showTimer = null;
        if (!mounted || !widget.state.busy) return;
        setState(() {
          _indicatorVisible = true;
          _shownAt = DateTime.now();
        });
      });
      return;
    }

    _showTimer?.cancel();
    _showTimer = null;
    if (!_indicatorVisible) return;
    final shownAt = _shownAt ?? DateTime.now();
    final elapsed = DateTime.now().difference(shownAt);
    final remaining = widget.minimumVisibleDuration - elapsed;
    if (remaining <= Duration.zero) {
      setState(() => _indicatorVisible = false);
    } else {
      _hideTimer = Timer(remaining, () {
        _hideTimer = null;
        if (mounted && !widget.state.busy) {
          setState(() => _indicatorVisible = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveLabel = widget.label.isNotEmpty
        ? widget.label
        : widget.state.label;
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 150);

    if (widget.presentation == BusyPresentation.replace) {
      return AnimatedSwitcher(
        duration: duration,
        child: _indicatorVisible
            ? ConstrainedBox(
                key: const ValueKey('busy-replace'),
                constraints: BoxConstraints(minHeight: widget.minHeight),
                child: Center(
                  child: ThemedActivityIndicator(label: effectiveLabel),
                ),
              )
            : AbsorbPointer(
                key: const ValueKey('busy-content'),
                absorbing: widget.blockInput && widget.state.busy,
                child: widget.child,
              ),
      );
    }

    if (widget.presentation == BusyPresentation.inline) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: duration,
            child: _indicatorVisible
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ThemedActivityIndicator(
                        compact: true,
                        label: effectiveLabel,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          AbsorbPointer(
            absorbing: widget.blockInput && widget.state.busy,
            child: widget.child,
          ),
        ],
      );
    }

    final activity = context.activityTheme;
    return Stack(
      children: [
        AbsorbPointer(
          absorbing: widget.blockInput && widget.state.busy,
          child: AnimatedOpacity(
            duration: duration,
            opacity: _indicatorVisible ? activity.disabledOpacity : 1,
            child: widget.child,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_indicatorVisible,
            child: AnimatedOpacity(
              duration: duration,
              opacity: _indicatorVisible ? 1 : 0,
              child: ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: activity.overlayOpacity),
                child: Center(
                  child: ThemedActivityIndicator(label: effectiveLabel),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
