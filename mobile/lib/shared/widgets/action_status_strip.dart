import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../formatters/operation_status.dart';

class ActionStatusStrip extends StatelessWidget {
  const ActionStatusStrip({super.key, required this.action});

  final String action;

  @override
  Widget build(BuildContext context) {
    final label = operationLabel(action);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: label == null
          ? const SizedBox.shrink()
          : Container(
              key: ValueKey(label),
              height: 28,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: context.statusTheme.statusBackground,
                border: Border(
                  bottom: BorderSide(color: context.statusTheme.statusBorder),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.statusTheme.warning,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
