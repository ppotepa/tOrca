import 'package:flutter/material.dart';

import '../extensions/torchat_chat_theme.dart';
import '../extensions/torchat_effects_theme.dart';
import '../extensions/torchat_inbox_theme.dart';
import '../extensions/torchat_shell_theme.dart';
import '../extensions/torchat_status_theme.dart';
import '../theme_preferences.dart';

ThemeData buildRetroDarkTheme([
  TorChatRetroPalette palette = TorChatRetroPalette.mocha,
]) {
  final colors = _retroPalette(palette, Brightness.dark);
  final primary = colors.primary;
  final secondary = colors.info;
  final tertiary = colors.accent;
  final background = colors.background;
  final surface = colors.surface;
  final raisedSurface = colors.raisedSurface;
  final border = colors.border;
  final text = colors.text;
  final muted = colors.muted;
  final success = colors.success;
  final danger = colors.danger;
  final warning = colors.warning;
  final incoming = colors.incoming;
  final outgoing = colors.outgoing;

  final shadow = BoxShadow(
    color: colors.shadow,
    offset: Offset(4, 4),
    blurRadius: 0,
  );

  final scheme =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: primary,
        secondary: secondary,
        tertiary: tertiary,
        surface: surface,
        surfaceContainerLowest: background,
        surfaceContainerLow: surface,
        surfaceContainer: raisedSurface,
        surfaceContainerHigh: raisedSurface,
        surfaceContainerHighest: raisedSurface,
        outline: border,
        outlineVariant: muted,
        onSurface: text,
        onPrimary: text,
        onSecondary: background,
        error: danger,
        onError: background,
      );

  return ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'PixelifySans',
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    useMaterial3: true,
    textTheme: ThemeData.dark().textTheme
        .apply(fontFamily: 'PixelifySans')
        .copyWith(
          displaySmall: const TextStyle(
            fontFamily: 'PressStart2P',
            fontSize: 20,
            height: 1.6,
          ),
          headlineSmall: const TextStyle(
            fontFamily: 'PressStart2P',
            fontSize: 16,
            height: 1.6,
          ),
          labelLarge: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
          labelMedium: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: const TextStyle(
            fontFamily: 'PressStart2P',
            fontSize: 12,
            height: 1.5,
            fontWeight: FontWeight.w700,
          ),
          bodyLarge: const TextStyle(fontSize: 16, height: 1.4),
          bodyMedium: const TextStyle(fontSize: 15, height: 1.4),
          bodySmall: TextStyle(color: muted, fontSize: 13, height: 1.4),
        ),
    dividerTheme: DividerThemeData(color: border, thickness: 3, space: 3),
    cardTheme: _retroCardTheme(surface, border),
    inputDecorationTheme: _retroInputTheme(raisedSurface, border, secondary),
    elevatedButtonTheme: _retroElevatedButtonTheme(primary, text, border),
    outlinedButtonTheme: _retroOutlinedButtonTheme(surface, text, border),
    navigationBarTheme: _retroNavigationTheme(surface, tertiary, text),
    chipTheme: _retroChipTheme(raisedSurface, text, border),
    segmentedButtonTheme: _retroSegmentedButtonTheme(
      raisedSurface,
      tertiary,
      text,
      border,
    ),
    filledButtonTheme: _retroFilledButtonTheme(primary, text, border),
    textButtonTheme: _retroTextButtonTheme(text),
    dialogTheme: _retroDialogTheme(surface, border),
    snackBarTheme: _retroSnackBarTheme(raisedSurface, text, border),
    iconButtonTheme: _retroIconButtonTheme(border),
    extensions: [
      TorChatChatTheme(
        incomingBubble: incoming,
        incomingForeground: text,
        outgoingBubble: outgoing,
        outgoingForeground: text,
        metadataForeground: tertiary,
        composerBackground: raisedSurface,
        composerBorder: border,
        unreadBackground: warning.withValues(alpha: .13),
        unreadBorder: warning.withValues(alpha: .45),
        bubbleRadius: 0,
        bubbleBorderWidth: 3,
        bubblePadding: const EdgeInsets.fromLTRB(14, 10, 12, 7),
        bubbleShadow: [shadow],
      ),
      TorChatShellTheme(
        background: background,
        surface: surface,
        raisedSurface: raisedSurface,
        border: border,
        selectedNavigationBackground: tertiary.withValues(alpha: .18),
        selectedNavigationBorder: tertiary,
        navigationForeground: muted,
        selectedNavigationForeground: text,
        panelRadius: 0,
        borderWidth: 3,
        listItemRadius: 0,
        listItemBorderWidth: 3,
      ),
      TorChatInboxTheme(
        accept: success,
        acceptForeground: background,
        reject: danger,
        rejectForeground: background,
        archive: raisedSurface,
        archiveForeground: text,
        pending: background,
        pendingBorderWidth: 3,
        completed: success.withValues(alpha: .18),
        actionRadius: 0,
        cardRadius: 0,
        cardBorderWidth: 3,
        actionMinWidth: 72,
        actionMinHeight: 58,
        actionPaddingHorizontal: 26,
        actionIconSize: 20,
      ),
      TorChatStatusTheme(
        success: success,
        warning: warning,
        danger: danger,
        offline: muted,
        statusBackground: success.withValues(alpha: .10),
        statusForeground: text,
        statusBorder: border,
      ),
      TorChatEffectsTheme(
        raisedShadow: [shadow],
        alertGlow: [shadow],
        pressOffset: 4,
        pixelated: true,
        scanlines: false,
      ),
    ],
  );
}

ThemeData buildRetroLightTheme([
  TorChatRetroPalette palette = TorChatRetroPalette.mocha,
]) {
  final colors = _retroPalette(palette, Brightness.light);
  final primary = colors.primary;
  final secondary = colors.info;
  final tertiary = colors.accent;
  final background = colors.background;
  final surface = colors.surface;
  final raisedSurface = colors.raisedSurface;
  final border = colors.border;
  final text = colors.text;
  final muted = colors.muted;
  final success = colors.success;
  final danger = colors.danger;
  final warning = colors.warning;
  final incoming = colors.incoming;
  final outgoing = colors.outgoing;

  final shadow = BoxShadow(
    color: colors.shadow,
    offset: Offset(4, 4),
    blurRadius: 0,
  );

  final scheme =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: primary,
        secondary: secondary,
        tertiary: tertiary,
        surface: surface,
        surfaceContainerLowest: background,
        surfaceContainerLow: surface,
        surfaceContainer: raisedSurface,
        surfaceContainerHigh: raisedSurface,
        surfaceContainerHighest: raisedSurface,
        outline: border,
        outlineVariant: muted,
        onSurface: text,
        onPrimary: background,
        onSecondary: background,
        error: danger,
        onError: background,
      );

  return ThemeData(
    brightness: Brightness.light,
    fontFamily: 'PixelifySans',
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    useMaterial3: true,
    textTheme: ThemeData.light().textTheme
        .apply(fontFamily: 'PixelifySans')
        .copyWith(
          displaySmall: const TextStyle(
            fontFamily: 'PressStart2P',
            fontSize: 20,
            height: 1.6,
          ),
          headlineSmall: const TextStyle(
            fontFamily: 'PressStart2P',
            fontSize: 16,
            height: 1.6,
          ),
          labelLarge: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
          labelMedium: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: const TextStyle(
            fontFamily: 'PressStart2P',
            fontSize: 12,
            height: 1.5,
            fontWeight: FontWeight.w700,
          ),
          bodyLarge: const TextStyle(fontSize: 16, height: 1.4),
          bodyMedium: const TextStyle(fontSize: 15, height: 1.4),
          bodySmall: TextStyle(color: muted, fontSize: 13, height: 1.4),
        ),
    dividerTheme: DividerThemeData(color: border, thickness: 3, space: 3),
    cardTheme: _retroCardTheme(surface, border),
    inputDecorationTheme: _retroInputTheme(raisedSurface, border, secondary),
    elevatedButtonTheme: _retroElevatedButtonTheme(primary, background, border),
    outlinedButtonTheme: _retroOutlinedButtonTheme(surface, text, border),
    navigationBarTheme: _retroNavigationTheme(surface, primary, text),
    chipTheme: _retroChipTheme(raisedSurface, text, border),
    segmentedButtonTheme: _retroSegmentedButtonTheme(
      raisedSurface,
      primary,
      text,
      border,
    ),
    filledButtonTheme: _retroFilledButtonTheme(primary, background, border),
    textButtonTheme: _retroTextButtonTheme(text),
    dialogTheme: _retroDialogTheme(surface, border),
    snackBarTheme: _retroSnackBarTheme(raisedSurface, text, border),
    iconButtonTheme: _retroIconButtonTheme(border),
    extensions: [
      TorChatChatTheme(
        incomingBubble: incoming,
        incomingForeground: text,
        outgoingBubble: outgoing,
        outgoingForeground: text,
        metadataForeground: text,
        composerBackground: raisedSurface,
        composerBorder: border,
        unreadBackground: warning.withValues(alpha: .14),
        unreadBorder: warning.withValues(alpha: .55),
        bubbleRadius: 0,
        bubbleBorderWidth: 3,
        bubblePadding: const EdgeInsets.fromLTRB(14, 10, 12, 7),
        bubbleShadow: [shadow],
      ),
      TorChatShellTheme(
        background: background,
        surface: surface,
        raisedSurface: raisedSurface,
        border: border,
        selectedNavigationBackground: primary.withValues(alpha: .16),
        selectedNavigationBorder: primary,
        navigationForeground: muted,
        selectedNavigationForeground: text,
        panelRadius: 0,
        borderWidth: 3,
        listItemRadius: 0,
        listItemBorderWidth: 3,
      ),
      TorChatInboxTheme(
        accept: success,
        acceptForeground: text,
        reject: danger,
        rejectForeground: background,
        archive: muted,
        archiveForeground: background,
        pending: background,
        pendingBorderWidth: 3,
        completed: success.withValues(alpha: .16),
        actionRadius: 0,
        cardRadius: 0,
        cardBorderWidth: 3,
        actionMinWidth: 72,
        actionMinHeight: 58,
        actionPaddingHorizontal: 26,
        actionIconSize: 20,
      ),
      TorChatStatusTheme(
        success: success,
        warning: warning,
        danger: danger,
        offline: muted,
        statusBackground: success.withValues(alpha: .10),
        statusForeground: text,
        statusBorder: border,
      ),
      TorChatEffectsTheme(
        raisedShadow: [shadow],
        alertGlow: [shadow],
        pressOffset: 4,
        pixelated: true,
        scanlines: false,
      ),
    ],
  );
}

CardThemeData _retroCardTheme(Color background, Color border) => CardThemeData(
  color: background,
  elevation: 0,
  margin: EdgeInsets.zero,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.zero,
    side: BorderSide(color: border, width: 3),
  ),
);

InputDecorationTheme _retroInputTheme(
  Color background,
  Color border,
  Color focus,
) => InputDecorationTheme(
  filled: true,
  fillColor: background,
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(color: border, width: 3),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(color: border, width: 3),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(color: focus, width: 4),
  ),
);

ElevatedButtonThemeData _retroElevatedButtonTheme(
  Color background,
  Color foreground,
  Color border,
) => ElevatedButtonThemeData(
  style: ButtonStyle(
    elevation: const WidgetStatePropertyAll(0),
    backgroundColor: WidgetStatePropertyAll(background),
    foregroundColor: WidgetStatePropertyAll(foreground),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: border, width: 3),
      ),
    ),
  ),
);

OutlinedButtonThemeData _retroOutlinedButtonTheme(
  Color background,
  Color foreground,
  Color border,
) => OutlinedButtonThemeData(
  style: ButtonStyle(
    backgroundColor: WidgetStatePropertyAll(background),
    foregroundColor: WidgetStatePropertyAll(foreground),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    ),
    side: WidgetStatePropertyAll(BorderSide(color: border, width: 3)),
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
  ),
);

NavigationBarThemeData _retroNavigationTheme(
  Color background,
  Color selected,
  Color foreground,
) => NavigationBarThemeData(
  backgroundColor: background,
  elevation: 0,
  height: 76,
  indicatorColor: selected,
  indicatorShape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
  labelTextStyle: WidgetStatePropertyAll(
    TextStyle(
      color: foreground,
      fontFamily: 'PixelifySans',
      fontSize: 12,
      fontWeight: FontWeight.w700,
    ),
  ),
);

ChipThemeData _retroChipTheme(Color background, Color text, Color border) =>
    ChipThemeData(
      backgroundColor: background,
      selectedColor: background,
      side: BorderSide(color: border, width: 3),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      labelStyle: TextStyle(
        color: text,
        fontFamily: 'PixelifySans',
        fontWeight: FontWeight.w700,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );

SegmentedButtonThemeData _retroSegmentedButtonTheme(
  Color background,
  Color selected,
  Color foreground,
  Color border,
) => SegmentedButtonThemeData(
  style: ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected) ? selected : background,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? _contrastColor(selected)
          : foreground,
    ),
    side: WidgetStatePropertyAll(BorderSide(color: border, width: 3)),
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    ),
  ),
);

FilledButtonThemeData _retroFilledButtonTheme(
  Color background,
  Color foreground,
  Color border,
) => FilledButtonThemeData(
  style: ButtonStyle(
    backgroundColor: WidgetStatePropertyAll(background),
    foregroundColor: WidgetStatePropertyAll(foreground),
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
    side: WidgetStatePropertyAll(BorderSide(color: border, width: 3)),
  ),
);

TextButtonThemeData _retroTextButtonTheme(Color foreground) =>
    TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(foreground),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
      ),
    );

DialogThemeData _retroDialogTheme(Color background, Color border) =>
    DialogThemeData(
      backgroundColor: background,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: border, width: 3),
      ),
    );

SnackBarThemeData _retroSnackBarTheme(
  Color background,
  Color text,
  Color border,
) => SnackBarThemeData(
  backgroundColor: background,
  contentTextStyle: TextStyle(color: text, fontFamily: 'PixelifySans'),
  behavior: SnackBarBehavior.floating,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.zero,
    side: BorderSide(color: border, width: 3),
  ),
);

IconButtonThemeData _retroIconButtonTheme(Color border) => IconButtonThemeData(
  style: ButtonStyle(
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
    side: WidgetStatePropertyAll(BorderSide(color: border, width: 2)),
  ),
);

Color _contrastColor(Color background) =>
    background.computeLuminance() > .48 ? Colors.black : Colors.white;

_RetroPalette _retroPalette(
  TorChatRetroPalette palette,
  Brightness brightness,
) {
  final dark = brightness == Brightness.dark;
  return switch ((palette, dark)) {
    (TorChatRetroPalette.arcade, true) => const _RetroPalette(
      primary: Color(0xffE52521),
      info: Color(0xff049CD8),
      accent: Color(0xffFBD000),
      background: Color(0xff0D0D0D),
      surface: Color(0xff171717),
      raisedSurface: Color(0xff242424),
      border: Color(0xffF7F7F7),
      text: Color(0xffFFFFFF),
      muted: Color(0xffB8B8B8),
      success: Color(0xff61D095),
      danger: Color(0xffEF7180),
      warning: Color(0xffE9B85D),
      incoming: Color(0xff292929),
      outgoing: Color(0xff244C3D),
      shadow: Color(0xff000000),
    ),
    (TorChatRetroPalette.arcade, false) => const _RetroPalette(
      primary: Color(0xffE52521),
      info: Color(0xff006FA6),
      accent: Color(0xffAA7200),
      background: Color(0xffF4F1E8),
      surface: Color(0xffFFFFFF),
      raisedSurface: Color(0xffFFF4C2),
      border: Color(0xff1A1A1A),
      text: Color(0xff1A1A1A),
      muted: Color(0xff585858),
      success: Color(0xff187A52),
      danger: Color(0xffB72F45),
      warning: Color(0xff9B6500),
      incoming: Color(0xffE8E8E8),
      outgoing: Color(0xffCDE9DA),
      shadow: Color(0xff1A1A1A),
    ),
    (TorChatRetroPalette.mocha, true) => const _RetroPalette(
      primary: Color(0xff89B4FA),
      info: Color(0xff74C7EC),
      accent: Color(0xffCBA6F7),
      background: Color(0xff11111B),
      surface: Color(0xff181825),
      raisedSurface: Color(0xff313244),
      border: Color(0xff6C7086),
      text: Color(0xffCDD6F4),
      muted: Color(0xffA6ADC8),
      success: Color(0xffA6E3A1),
      danger: Color(0xffF38BA8),
      warning: Color(0xffFAB387),
      incoming: Color(0xff242435),
      outgoing: Color(0xff294436),
      shadow: Color(0xff07070C),
    ),
    (TorChatRetroPalette.mocha, false) => const _RetroPalette(
      primary: Color(0xff1E66F5),
      info: Color(0xff209FB5),
      accent: Color(0xff8839EF),
      background: Color(0xffEFF1F5),
      surface: Color(0xffE6E9EF),
      raisedSurface: Color(0xffDCE0E8),
      border: Color(0xff7C7F93),
      text: Color(0xff4C4F69),
      muted: Color(0xff6C6F85),
      success: Color(0xff40944B),
      danger: Color(0xffD20F39),
      warning: Color(0xffB55D00),
      incoming: Color(0xffDCE0E8),
      outgoing: Color(0xffC8E6CF),
      shadow: Color(0xff9CA0B0),
    ),
    (TorChatRetroPalette.gruvbox, true) => const _RetroPalette(
      primary: Color(0xff83A598),
      info: Color(0xff8EC07C),
      accent: Color(0xffD3869B),
      background: Color(0xff1D2021),
      surface: Color(0xff282828),
      raisedSurface: Color(0xff3C3836),
      border: Color(0xffA89984),
      text: Color(0xffEBDBB2),
      muted: Color(0xffBDAE93),
      success: Color(0xffB8BB26),
      danger: Color(0xffFB4934),
      warning: Color(0xffFE8019),
      incoming: Color(0xff32302F),
      outgoing: Color(0xff3B4431),
      shadow: Color(0xff0F1111),
    ),
    (TorChatRetroPalette.gruvbox, false) => const _RetroPalette(
      primary: Color(0xff076678),
      info: Color(0xff427B58),
      accent: Color(0xff8F3F71),
      background: Color(0xffFBF1C7),
      surface: Color(0xffF2E5BC),
      raisedSurface: Color(0xffEBDBB2),
      border: Color(0xff7C6F64),
      text: Color(0xff3C3836),
      muted: Color(0xff665C54),
      success: Color(0xff79740E),
      danger: Color(0xff9D0006),
      warning: Color(0xffAF3A03),
      incoming: Color(0xffEBDBB2),
      outgoing: Color(0xffD9E2B7),
      shadow: Color(0xffBDAE93),
    ),
    (TorChatRetroPalette.nord, true) => const _RetroPalette(
      primary: Color(0xff88C0D0),
      info: Color(0xff81A1C1),
      accent: Color(0xffB48EAD),
      background: Color(0xff2E3440),
      surface: Color(0xff3B4252),
      raisedSurface: Color(0xff434C5E),
      border: Color(0xffD8DEE9),
      text: Color(0xffECEFF4),
      muted: Color(0xffD8DEE9),
      success: Color(0xffA3BE8C),
      danger: Color(0xffBF616A),
      warning: Color(0xffD08770),
      incoming: Color(0xff3B4252),
      outgoing: Color(0xff405747),
      shadow: Color(0xff20242C),
    ),
    (TorChatRetroPalette.nord, false) => const _RetroPalette(
      primary: Color(0xff3B6F82),
      info: Color(0xff4C6F91),
      accent: Color(0xff7C5C78),
      background: Color(0xffECEFF4),
      surface: Color(0xffE5E9F0),
      raisedSurface: Color(0xffD8DEE9),
      border: Color(0xff4C566A),
      text: Color(0xff2E3440),
      muted: Color(0xff4C566A),
      success: Color(0xff4F6F3E),
      danger: Color(0xff9B3E47),
      warning: Color(0xffA5543E),
      incoming: Color(0xffD8DEE9),
      outgoing: Color(0xffD2E2D1),
      shadow: Color(0xffA7ADBA),
    ),
  };
}

final class _RetroPalette {
  const _RetroPalette({
    required this.primary,
    required this.info,
    required this.accent,
    required this.background,
    required this.surface,
    required this.raisedSurface,
    required this.border,
    required this.text,
    required this.muted,
    required this.success,
    required this.danger,
    required this.warning,
    required this.incoming,
    required this.outgoing,
    required this.shadow,
  });

  final Color primary;
  final Color info;
  final Color accent;
  final Color background;
  final Color surface;
  final Color raisedSurface;
  final Color border;
  final Color text;
  final Color muted;
  final Color success;
  final Color danger;
  final Color warning;
  final Color incoming;
  final Color outgoing;
  final Color shadow;
}
