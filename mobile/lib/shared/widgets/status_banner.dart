import 'package:flutter/material.dart';
import '../../app/app_theme.dart';

class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.message, required this.color});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      border: Border.all(color: color.withValues(alpha: .72)),
      borderRadius: context.effectsTheme.pixelated
          ? BorderRadius.zero
          : BorderRadius.circular(10),
    ),
    child: Text(message, style: TextStyle(color: color)),
  );
}
