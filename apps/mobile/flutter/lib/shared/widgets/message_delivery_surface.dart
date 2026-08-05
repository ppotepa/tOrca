import 'package:flutter/material.dart';

import 'package:torchat_flutter_ui/core/models/domain.dart';

class MessageDeliverySurface extends StatefulWidget {
  const MessageDeliverySurface({
    super.key,
    required this.state,
    required this.child,
  });

  final MessageState state;
  final Widget child;

  @override
  State<MessageDeliverySurface> createState() => _MessageDeliverySurfaceState();
}

class _MessageDeliverySurfaceState extends State<MessageDeliverySurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  bool _animationsDisabled = false;

  bool get _animated =>
      widget.state == MessageState.queued ||
      widget.state == MessageState.sending;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant MessageDeliverySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (_animated && !_animationsDisabled) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animationsDisabled = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Opacity(
        opacity: !_animated ? 1 : .46 + (_pulse.value * .14),
        child: child,
      ),
      child: widget.child,
    ),
  );
}
