import 'package:flutter/material.dart';

class TorChatStatusTheme extends ThemeExtension<TorChatStatusTheme> {
  const TorChatStatusTheme({
    required this.success,
    required this.warning,
    required this.danger,
    required this.offline,
    required this.statusBackground,
    required this.statusForeground,
    required this.statusBorder,
  });

  final Color success;
  final Color warning;
  final Color danger;
  final Color offline;
  final Color statusBackground;
  final Color statusForeground;
  final Color statusBorder;

  @override
  ThemeExtension<TorChatStatusTheme> copyWith({
    Color? success,
    Color? warning,
    Color? danger,
    Color? offline,
    Color? statusBackground,
    Color? statusForeground,
    Color? statusBorder,
  }) => TorChatStatusTheme(
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    offline: offline ?? this.offline,
    statusBackground: statusBackground ?? this.statusBackground,
    statusForeground: statusForeground ?? this.statusForeground,
    statusBorder: statusBorder ?? this.statusBorder,
  );

  @override
  ThemeExtension<TorChatStatusTheme> lerp(
    covariant ThemeExtension<TorChatStatusTheme>? other,
    double t,
  ) {
    if (other is! TorChatStatusTheme) return this;
    return TorChatStatusTheme(
      success: Color.lerp(success, other.success, t) ?? success,
      warning: Color.lerp(warning, other.warning, t) ?? warning,
      danger: Color.lerp(danger, other.danger, t) ?? danger,
      offline: Color.lerp(offline, other.offline, t) ?? offline,
      statusBackground:
          Color.lerp(statusBackground, other.statusBackground, t) ??
          statusBackground,
      statusForeground:
          Color.lerp(statusForeground, other.statusForeground, t) ??
          statusForeground,
      statusBorder:
          Color.lerp(statusBorder, other.statusBorder, t) ?? statusBorder,
    );
  }
}

extension TorChatStatusThemeContext on BuildContext {
  TorChatStatusTheme get statusTheme =>
      Theme.of(this).extension<TorChatStatusTheme>() ??
      (() {
        final scheme = Theme.of(this).colorScheme;
        return TorChatStatusTheme(
          success: scheme.primary,
          warning: scheme.secondary,
          danger: scheme.error,
          offline: scheme.outline,
          statusBackground: scheme.surfaceContainerHighest.withValues(
            alpha: 0.12,
          ),
          statusForeground: scheme.onSurfaceVariant,
          statusBorder: scheme.outlineVariant,
        );
      })();
}
