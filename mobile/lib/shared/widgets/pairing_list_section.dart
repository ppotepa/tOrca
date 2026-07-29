import 'package:flutter/material.dart';

import 'empty_state.dart';

class PairingListSection<T> extends StatelessWidget {
  const PairingListSection({
    super.key,
    required this.title,
    required this.items,
    required this.itemBuilder,
    this.emptyMessage = 'Brak zaproszeń.',
    this.emptyIcon = Icons.inbox_outlined,
    this.dividerHeight = 6,
  });

  final String title;
  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final String emptyMessage;
  final IconData emptyIcon;
  final double dividerHeight;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      if (items.isEmpty)
        EmptyState(icon: emptyIcon, message: emptyMessage)
      else
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          separatorBuilder: (_, _) => SizedBox(height: dividerHeight),
          itemBuilder: (context, index) => itemBuilder(context, items[index]),
        ),
    ],
  );
}
