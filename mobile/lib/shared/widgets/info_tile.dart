import 'package:flutter/material.dart';

class InfoTile extends StatelessWidget {
  const InfoTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.contentPadding = EdgeInsets.zero,
    this.subtitleSelectable = false,
  });

  final String title;
  final String subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry contentPadding;
  final bool subtitleSelectable;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: contentPadding,
    leading: leading,
    trailing: trailing,
    onTap: onTap,
    title: Text(title),
    subtitle: subtitleSelectable ? SelectableText(subtitle) : Text(subtitle),
  );
}
