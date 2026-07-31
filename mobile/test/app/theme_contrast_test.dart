import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torchat_mobile/app/theme/extensions/torchat_chat_theme.dart';
import 'package:torchat_mobile/app/theme/extensions/torchat_inbox_theme.dart';
import 'package:torchat_mobile/app/theme/theme_preferences.dart';
import 'package:torchat_mobile/app/theme/theme_registry.dart';

void main() {
  for (final family in TorChatThemeFamily.values) {
    for (final palette in TorChatRetroPalette.values) {
      test('$family $palette colors meet text contrast', () {
        for (final theme in [
          TorChatThemeRegistry.light(family, retroPalette: palette),
          TorChatThemeRegistry.dark(family, retroPalette: palette),
        ]) {
          final scheme = theme.colorScheme;
          final chat = theme.extension<TorChatChatTheme>()!;
          final inbox = theme.extension<TorChatInboxTheme>()!;
          final pairs = <(Color, Color)>[
            (scheme.surface, scheme.onSurface),
            (scheme.primary, scheme.onPrimary),
            (scheme.secondary, scheme.onSecondary),
            (scheme.tertiary, scheme.onTertiary),
            (scheme.error, scheme.onError),
            (scheme.primaryContainer, scheme.onPrimaryContainer),
            (scheme.secondaryContainer, scheme.onSecondaryContainer),
            (scheme.tertiaryContainer, scheme.onTertiaryContainer),
            (scheme.errorContainer, scheme.onErrorContainer),
            (chat.incomingBubble, chat.incomingForeground),
            (chat.outgoingBubble, chat.outgoingForeground),
            (inbox.accept, inbox.acceptForeground),
            (inbox.reject, inbox.rejectForeground),
            (inbox.archive, inbox.archiveForeground),
          ];
          for (final pair in pairs) {
            expect(
              contrastRatio(pair.$1, pair.$2),
              greaterThanOrEqualTo(4.5),
              reason: '${pair.$1} / ${pair.$2} in ${theme.brightness}',
            );
          }
        }
      });
    }
  }

  test('accessible foreground selects the stronger black or white contrast', () {
    const green = Color(0xff187a52);
    final foreground = accessibleForeground(green);
    expect(contrastRatio(green, foreground), greaterThanOrEqualTo(4.5));
  });
}
