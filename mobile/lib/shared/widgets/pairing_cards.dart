import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';

class PairingStatusChip extends StatelessWidget {
  const PairingStatusChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Chip(
    label: Text(label),
    visualDensity: VisualDensity.compact,
    side: BorderSide(color: context.shellTheme.border),
  );
}

class PairingRecordCard extends StatelessWidget {
  const PairingRecordCard({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.pendingTrailing,
    required this.completedTrailing,
    this.pendingBorderColor,
    this.backgroundColor,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final InviteState status;
  final Widget pendingTrailing;
  final Widget completedTrailing;
  final Color? pendingBorderColor;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final pending = status == InviteState.pending;
    final inbox = context.inboxTheme;
    return Card(
      color:
          backgroundColor ??
          (pending ? inbox.pending : context.statusTheme.statusBackground),
      shape: pending
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(inbox.cardRadius),
              side: BorderSide(
                color: pendingBorderColor ?? inbox.reject,
                width: inbox.pendingBorderWidth,
              ),
            )
          : null,
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: leading,
        title: Text(title),
        subtitle: Text(subtitle),
        isThreeLine: subtitle.contains('\n'),
        trailing: pending ? pendingTrailing : completedTrailing,
      ),
    );
  }
}
