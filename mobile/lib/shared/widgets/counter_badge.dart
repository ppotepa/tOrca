import 'package:flutter/material.dart';
import '../../app/app_theme.dart';

class CounterBadge extends StatelessWidget {
  const CounterBadge({
    super.key,
    required this.count,
    this.child,
    this.color,
    this.glow = false,
  });

  final int count;
  final Widget? child;
  final Color? color;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child ?? const SizedBox.shrink();
    final status = context.statusTheme;
    final badgeColor = color ?? status.warning;
    final badgeTextColor = badgeColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor,
        borderRadius: context.effectsTheme.pixelated
            ? BorderRadius.zero
            : BorderRadius.circular(999),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: badgeColor.withValues(alpha: .40),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: badgeTextColor,
          fontWeight: FontWeight.w800,
        ),
      ),
    );

    if (child == null) return badge;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child!,
        Positioned(right: -6, top: -6, child: badge),
      ],
    );
  }
}
