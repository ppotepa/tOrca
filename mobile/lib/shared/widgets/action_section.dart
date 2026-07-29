import 'package:flutter/material.dart';

import 'section_card.dart';

class ActionSection extends StatelessWidget {
  const ActionSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String title;
  final Widget child;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: title,
    subtitle: subtitle,
    leading: leading,
    trailing: trailing,
    child: child,
  );
}
