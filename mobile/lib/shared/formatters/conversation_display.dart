import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/models/domain.dart';

String messageStateLabel(MessageState value) => value.label;

String conversationPresenceLabel(
  String? id,
  List<ConversationSummary> conversations,
) {
  final conversation = conversations.where((item) => item.id == id).firstOrNull;
  if (conversation == null) return 'brak danych';
  final state = conversation.state;
  return switch (state) {
    ConversationState.active => 'online',
    ConversationState.offline => 'offline',
    ConversationState.failed => 'niedostępny',
    _ => 'łączenie',
  };
}

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

String outboxTitle(PairingItem request) {
  final peer = request.peer;
  if (peer != null && peer.nickname.trim().isNotEmpty) {
    return 'Zaproszenie do @${peer.nickname}';
  }
  return 'Wysłane zaproszenie';
}
