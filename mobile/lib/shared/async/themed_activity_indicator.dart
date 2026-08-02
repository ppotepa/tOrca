import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/extensions/torchat_activity_theme.dart';

class ThemedActivityIndicator extends StatefulWidget {
  const ThemedActivityIndicator({
    super.key,
    this.label = '',
    this.compact = false,
    this.color,
  });

  final String label;
  final bool compact;
  final Color? color;

  @override
  State<ThemedActivityIndicator> createState() =>
      _ThemedActivityIndicatorState();
}

class _ThemedActivityIndicatorState extends State<ThemedActivityIndicator> {
  Timer? _timer;
  int _frame = 0;
  Duration? _duration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = context.activityTheme.frameDuration;
    if (_duration == duration) return;
    _duration = duration;
    _timer?.cancel();
    _timer = Timer.periodic(duration, (_) {
      if (mounted) setState(() => _frame += 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activity = context.activityTheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: color,
      fontFamily: activity.fontFamily,
      fontWeight: FontWeight.w700,
    );
    final indicator = activity.kind == TorChatActivityIndicatorKind.material
        ? SizedBox.square(
            dimension: widget.compact ? 16 : 24,
            child: CircularProgressIndicator(
              strokeWidth: widget.compact ? 2 : 2.5,
              color: color,
            ),
          )
        : Text(
            activity.frames.isEmpty
                ? '…'
                : activity.frames[reduceMotion
                      ? 0
                      : _frame % activity.frames.length],
            style: labelStyle?.copyWith(fontSize: widget.compact ? 15 : 22),
          );

    return Semantics(
      label: widget.label.isEmpty ? 'Ładowanie' : widget.label,
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          indicator,
          if (widget.label.isNotEmpty) ...[
            SizedBox(width: widget.compact ? 7 : 10),
            Flexible(child: Text(widget.label, style: labelStyle)),
          ],
        ],
      ),
    );
  }
}
