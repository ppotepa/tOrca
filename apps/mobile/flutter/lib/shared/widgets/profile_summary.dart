import 'package:flutter/material.dart';

import 'identity_avatar.dart';

class ProfileSummary extends StatelessWidget {
  const ProfileSummary({
    super.key,
    required this.name,
    required this.subtitle,
    this.radius = 28,
  });

  final String name;
  final String subtitle;
  final double radius;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IdentityAvatar(label: name, radius: radius),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name.startsWith('@') ? name : '@$name',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
