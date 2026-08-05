import 'package:flutter/material.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.leading,
    this.trailing,
    this.backgroundColor,
    this.borderColor,
  });

  final String title;
  final Widget child;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final hasHeader =
        leading != null ||
        subtitle != null ||
        trailing != null ||
        title.isNotEmpty;

    return Card(
      color: backgroundColor,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor ?? Theme.of(context).dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasHeader) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[trailing!],
                ],
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}
