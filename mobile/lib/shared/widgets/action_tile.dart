import 'package:flutter/material.dart';

import 'info_tile.dart';

class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.leading,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget? leading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InfoTile(
    leading: leading,
    title: title,
    subtitle: subtitle,
    onTap: onTap,
    trailing: const Icon(Icons.chevron_right),
  );
}
