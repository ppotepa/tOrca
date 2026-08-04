import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';

String messageStateLabel(MessageState value) => value.wireValue;

String conversationLastSeenLabel(
  String? id,
  List<ConversationSummary> conversations,
) => '';

Color conversationPresenceColorByState(BuildContext context, String? state) {
  final theme = context.statusTheme;
  return switch (state?.toLowerCase()) {
    'online' => theme.success,
    'offline' => theme.danger,
    'łączenie' || 'connecting' => theme.warning,
    _ => theme.warning,
  };
}
