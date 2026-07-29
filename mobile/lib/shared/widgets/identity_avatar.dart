import 'package:flutter/material.dart';
import '../../app/app_theme.dart';

String identityInitial(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? '?' : normalized.characters.first.toUpperCase();
}

class IdentityAvatar extends StatelessWidget {
  const IdentityAvatar({
    super.key,
    required this.label,
    this.radius,
    this.backgroundColor,
  });

  final String label;
  final double? radius;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final diameter = (radius ?? 20) * 2;
    if (!context.effectsTheme.pixelated) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor,
        child: Text(identityInitial(label)),
      );
    }
    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            backgroundColor ??
            Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: Theme.of(context).colorScheme.outline,
          width: 2,
        ),
      ),
      child: Text(identityInitial(label)),
    );
  }
}
