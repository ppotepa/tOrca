import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

enum RetroActivityStyle { hourglass, dots, terminalCursor }

class RetroActivityIndicator extends StatefulWidget {
  const RetroActivityIndicator({
    super.key,
    this.style = RetroActivityStyle.hourglass,
    this.label = '',
    this.compact = false,
  });

  final RetroActivityStyle style;
  final String label;
  final bool compact;

  @override
  State<RetroActivityIndicator> createState() => _RetroActivityIndicatorState();
}

class _RetroActivityIndicatorState extends State<RetroActivityIndicator> {
  Timer? _timer;
  int _frame = 0;

  static const _hourglassFrames = ['⌛', '⧖', '⧗', '⏳'];
  static const _dotFrames = ['·  ', '·· ', '···'];
  static const _cursorFrames = ['▌', ' '];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 320), (_) {
      if (mounted) setState(() => _frame += 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<String> get _frames => switch (widget.style) {
    RetroActivityStyle.hourglass => _hourglassFrames,
    RetroActivityStyle.dots => _dotFrames,
    RetroActivityStyle.terminalCursor => _cursorFrames,
  };

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final frames = _frames;
    final glyph = frames[reduceMotion ? 0 : _frame % frames.length];
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      fontWeight: FontWeight.w700,
      color: context.statusTheme.warning,
    );

    return Semantics(
      label: widget.label.isEmpty ? 'Ładowanie' : widget.label,
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(glyph, style: textStyle?.copyWith(fontSize: widget.compact ? 14 : 20)),
          if (widget.label.isNotEmpty) ...[
            SizedBox(width: widget.compact ? 6 : 10),
            Flexible(child: Text(widget.label, style: textStyle)),
          ],
        ],
      ),
    );
  }
}
