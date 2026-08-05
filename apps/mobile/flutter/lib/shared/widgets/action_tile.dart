import 'package:flutter/material.dart';

import 'package:torchat_flutter_ui/async/themed_activity_indicator.dart';
import 'info_tile.dart';

class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.leading,
    this.onTap,
    this.busy = false,
    this.busyLabel,
  });

  final String title;
  final String subtitle;
  final Widget? leading;
  final VoidCallback? onTap;
  final bool busy;
  final String? busyLabel;

  @override
  Widget build(BuildContext context) => InfoTile(
    leading: busy ? const ThemedActivityIndicator(compact: true) : leading,
    title: busy ? busyLabel ?? title : title,
    subtitle: subtitle,
    onTap: busy ? null : onTap,
    trailing: busy ? const SizedBox.shrink() : const Icon(Icons.chevron_right),
  );
}
