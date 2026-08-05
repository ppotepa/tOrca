import 'package:flutter/material.dart';

class CalloutCard extends StatelessWidget {
  const CalloutCard({
    super.key,
    required this.child,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.backgroundColor,
    this.borderColor,
  });

  final Widget child;
  final Widget? leading;
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final hasHeader =
        leading != null ||
        title != null ||
        subtitle != null ||
        trailing != null;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasHeader)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Text(
                        title!,
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
        if (hasHeader) ...[const SizedBox(height: 12)],
        child,
      ],
    );

    return Card(
      color: backgroundColor,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor ?? Theme.of(context).dividerColor),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: content),
    );
  }
}
