import 'package:flutter/material.dart';

import 'themed_activity_indicator.dart';

class BusyActionButton extends StatelessWidget {
  const BusyActionButton({
    super.key,
    required this.busy,
    required this.label,
    required this.onPressed,
    this.busyLabel,
    this.icon,
    this.outlined = false,
  });

  final bool busy;
  final String label;
  final String? busyLabel;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final child = AnimatedSwitcher(
      duration: const Duration(milliseconds: 140),
      child: busy
          ? ThemedActivityIndicator(
              key: const ValueKey('busy'),
              compact: true,
              label: busyLabel ?? label,
            )
          : Row(
              key: const ValueKey('idle'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[icon!, const SizedBox(width: 8)],
                Text(label),
              ],
            ),
    );
    return outlined
        ? OutlinedButton(onPressed: busy ? null : onPressed, child: child)
        : FilledButton(onPressed: busy ? null : onPressed, child: child);
  }
}

class BusyIconButton extends StatelessWidget {
  const BusyIconButton({
    super.key,
    required this.busy,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final bool busy;
  final Widget icon;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: busy ? null : onPressed,
    icon: busy ? const ThemedActivityIndicator(compact: true) : icon,
  );
}
