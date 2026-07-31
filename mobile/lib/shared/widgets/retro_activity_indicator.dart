import 'package:flutter/widgets.dart';

import '../async/themed_activity_indicator.dart';

enum RetroActivityStyle { hourglass, dots, terminalCursor }

@Deprecated('Use ThemedActivityIndicator directly.')
class RetroActivityIndicator extends StatelessWidget {
  const RetroActivityIndicator({
    super.key,
    this.style = RetroActivityStyle.hourglass,
    this.label = '',
    this.compact = false,
  });

  final RetroActivityStyle style;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) => ThemedActivityIndicator(
    label: label,
    compact: compact,
  );
}
