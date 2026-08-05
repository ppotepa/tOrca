import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:torchat_flutter_ui/app_theme.dart';
import '../../app/notifications/toast_message.dart';
import '../../app/notifications/ui_notification_center.dart';

class ToastHost extends ConsumerWidget {
  const ToastHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(uiNotificationCenterProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: IgnorePointer(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final toast in notifications.visible)
                        Padding(
                          key: ValueKey(toast.id),
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _ToastCard(toast: toast),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({required this.toast});

  final ToastMessage toast;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _position;

  @override
  void initState() {
    super.initState();
    final reduced = TorChatMotionPolicy.enabled;
    _controller = AnimationController(
      vsync: this,
      duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
      reverseDuration: reduced
          ? Duration.zero
          : UiNotificationCenter.exitDuration,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _position = Tween<Offset>(
      begin: const Offset(0, -0.35),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant _ToastCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.toast.exiting && widget.toast.exiting) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = context.statusTheme;
    final color = switch (widget.toast.kind) {
      ToastKind.success => status.success,
      ToastKind.info => status.statusForeground,
      ToastKind.warning => status.warning,
      ToastKind.error => status.danger,
    };
    final foreground = color.computeLuminance() > .5
        ? Colors.black
        : Colors.white;
    final icon = switch (widget.toast.kind) {
      ToastKind.success => Icons.check_circle_outline,
      ToastKind.info => Icons.info_outline,
      ToastKind.warning => Icons.warning_amber_outlined,
      ToastKind.error => Icons.error_outline,
    };
    return Semantics(
      liveRegion: true,
      label: widget.toast.message,
      child: ExcludeSemantics(
        child: SlideTransition(
          position: _position,
          child: FadeTransition(
            opacity: _opacity,
            child: Material(
              color: color,
              elevation: context.effectsTheme.pixelated ? 0 : 10,
              shape: RoundedRectangleBorder(
                borderRadius: context.effectsTheme.pixelated
                    ? BorderRadius.zero
                    : BorderRadius.circular(12),
                side: BorderSide(
                  color: foreground.withValues(alpha: .65),
                  width: 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: foreground, size: 20),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.toast.message,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
