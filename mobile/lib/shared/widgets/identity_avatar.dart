import 'package:flutter/material.dart';

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
  Widget build(BuildContext context) => CircleAvatar(
    radius: radius,
    backgroundColor: backgroundColor,
    child: Text(identityInitial(label)),
  );
}
