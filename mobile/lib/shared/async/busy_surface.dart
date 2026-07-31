import 'package:flutter/material.dart';

import '../../app/theme/extensions/torchat_activity_theme.dart';
import 'async_operation_state.dart';
import 'themed_activity_indicator.dart';

enum BusyPresentation { overlay, replace, inline }

class BusySurface extends StatelessWidget {
  const BusySurface({
    super.key,
    required this.state,
    required this.child,
    this.presentation = BusyPresentation.overlay,
    this.label = '',
    this.blockInput = true,
    this.minHeight = 96,
  });

  final AsyncOperationState state;
  final Widget child;
  final BusyPresentation presentation;
  final String label;
  final bool blockInput;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final busy = state.busy;
    final effectiveLabel = label.isNotEmpty ? label : state.label;
    if (!busy) return child;
    if (presentation == BusyPresentation.replace) {
      return ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Center(
          child: ThemedActivityIndicator(label: effectiveLabel),
        ),
      );
    }
    if (presentation == BusyPresentation.inline) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ThemedActivityIndicator(
                compact: true,
                label: effectiveLabel,
              ),
            ),
          ),
          child,
        ],
      );
    }

    final activity = context.activityTheme;
    return Stack(
      children: [
        Opacity(opacity: activity.disabledOpacity, child: child),
        Positioned.fill(
          child: AbsorbPointer(
            absorbing: blockInput,
            child: ColoredBox(
              color: Theme.of(context)
                  .colorScheme
                  .surface
                  .withValues(alpha: activity.overlayOpacity),
              child: Center(
                child: ThemedActivityIndicator(label: effectiveLabel),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
