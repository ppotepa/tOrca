import 'package:flutter/material.dart';

import 'section_card.dart';

class InfoListSection extends StatelessWidget {
  const InfoListSection({
    super.key,
    required this.title,
    required this.items,
    this.subtitle,
    this.leading,
    this.trailing,
    this.dividers = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> items;
  final bool dividers;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: title,
    subtitle: subtitle,
    leading: leading,
    trailing: trailing,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < items.length; index++) ...[
          items[index],
          if (dividers && index < items.length - 1) const Divider(),
        ],
      ],
    ),
  );
}
