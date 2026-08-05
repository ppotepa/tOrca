import 'package:flutter/material.dart';

import 'package:torchat_flutter_ui/app_theme.dart';
import '../../shared/formatters/message_timestamps.dart';

class ConversationHeaderAction extends StatelessWidget {
  const ConversationHeaderAction({
    super.key,
    required this.tooltip,
    required this.child,
    this.onPressed,
  });

  final String tooltip;
  final Widget child;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 40,
        child: onPressed == null
            ? DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: context.shellTheme.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(child: child),
              )
            : IconButton(
                onPressed: onPressed,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                icon: child,
              ),
      ),
    ),
  );
}

class InlineStatus extends StatelessWidget {
  const InlineStatus({super.key, required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    color: error
        ? context.statusTheme.danger.withValues(alpha: .12)
        : context.statusTheme.success.withValues(alpha: .1),
    child: Text(
      message,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: error ? context.statusTheme.danger : context.statusTheme.success,
      ),
    ),
  );
}

class DayDivider extends StatelessWidget {
  const DayDivider({super.key, required this.date});

  final String date;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: context.shellTheme.surface,
        border: Border.all(color: context.shellTheme.border),
        borderRadius: context.effectsTheme.pixelated
            ? BorderRadius.zero
            : BorderRadius.circular(999),
      ),
      child: Text(
        formatMessageDay(
          date,
          locale: Localizations.localeOf(context).toLanguageTag(),
        ),
        style: Theme.of(context).textTheme.labelSmall,
      ),
    ),
  );
}
