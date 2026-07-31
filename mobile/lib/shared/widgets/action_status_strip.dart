import 'package:flutter/widgets.dart';

@Deprecated('Busy state is rendered by the component that owns the operation.')
class ActionStatusStrip extends StatelessWidget {
  const ActionStatusStrip({super.key, required this.action});

  final String action;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
