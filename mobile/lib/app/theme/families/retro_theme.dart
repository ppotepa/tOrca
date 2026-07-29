import 'package:flutter/material.dart';

import '../extensions/torchat_chat_theme.dart';
import '../extensions/torchat_effects_theme.dart';
import '../extensions/torchat_inbox_theme.dart';
import '../extensions/torchat_shell_theme.dart';
import '../extensions/torchat_status_theme.dart';

ThemeData buildRetroDarkTheme() {
  const Color primary = Color(0xffE52521);
  const Color secondary = Color(0xff049CD8);
  const Color tertiary = Color(0xffFBD000);
  const Color background = Color(0xff0D0D0D);
  const Color surface = Color(0xff171717);
  const Color raisedSurface = Color(0xff242424);
  const Color border = Color(0xffF7F7F7);
  const Color text = Color(0xffFFFFFF);
  const Color muted = Color(0xffB8B8B8);
  const Color success = Color(0xff61d095);
  const Color danger = Color(0xffef7180);
  const Color warning = Color(0xffe9b85d);
  const Color incoming = Color(0xff292929);
  const Color outgoing = Color(0xff244c3d);

  final shadow = const BoxShadow(
    color: Color(0xff000000),
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
        outline: border,
        onSurface: text,
        onPrimary: text,
        error: danger,
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
    dividerTheme: const DividerThemeData(color: border, thickness: 3, space: 3),
    cardTheme: _retroCardTheme(surface, border),
    inputDecorationTheme: _retroInputTheme(raisedSurface, border, secondary),
    elevatedButtonTheme: _retroElevatedButtonTheme(primary, text, border),
    outlinedButtonTheme: _retroOutlinedButtonTheme(surface, text, border),
    navigationBarTheme: _retroNavigationTheme(surface, tertiary, text),
    chipTheme: _retroChipTheme(raisedSurface, text, border),
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
        unreadBackground: const Color(0x21ffcc80),
        unreadBorder: const Color(0x40ffcc80),
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
        selectedNavigationBackground: const Color(0xff3A2500),
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
        archive: border,
        archiveForeground: text,
        pending: background,
        pendingBorderWidth: 3,
        completed: const Color(0xff243224),
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
        statusBackground: const Color(0x1ad7973c),
        statusForeground: const Color(0xffedf2f7),
        statusBorder: const Color(0xff303944),
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

ThemeData buildRetroLightTheme() {
  const Color primary = Color(0xffE52521);
  const Color secondary = Color(0xff049CD8);
  const Color tertiary = Color(0xffFBD000);
  const Color background = Color(0xffF4F1E8);
  const Color surface = Color(0xffFFFFFF);
  const Color raisedSurface = Color(0xffFFF4C2);
  const Color border = Color(0xff1A1A1A);
  const Color text = Color(0xff1A1A1A);
  const Color muted = Color(0xff585858);
  const Color success = Color(0xff187a52);
  const Color danger = Color(0xffb72f45);
  const Color warning = Color(0xff9b6500);
  const Color incoming = Color(0xffE8E8E8);
  const Color outgoing = Color(0xffcde9da);

  final shadow = const BoxShadow(
    color: Color(0xff1A1A1A),
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
        outline: border,
        onSurface: text,
        onPrimary: const Color(0xffFFFFFF),
        error: danger,
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
    dividerTheme: const DividerThemeData(color: border, thickness: 3, space: 3),
    cardTheme: _retroCardTheme(surface, border),
    inputDecorationTheme: _retroInputTheme(raisedSurface, border, secondary),
    elevatedButtonTheme: _retroElevatedButtonTheme(
      primary,
      const Color(0xffFFFFFF),
      border,
    ),
    outlinedButtonTheme: _retroOutlinedButtonTheme(surface, text, border),
    navigationBarTheme: _retroNavigationTheme(surface, primary, text),
    chipTheme: _retroChipTheme(raisedSurface, text, border),
    dialogTheme: _retroDialogTheme(surface, border),
    snackBarTheme: _retroSnackBarTheme(raisedSurface, text, border),
    iconButtonTheme: _retroIconButtonTheme(border),
    extensions: [
      TorChatChatTheme(
        incomingBubble: incoming,
        incomingForeground: text,
        outgoingBubble: outgoing,
        outgoingForeground: const Color(0xff123c29),
        metadataForeground: text,
        composerBackground: raisedSurface,
        composerBorder: border,
        unreadBackground: const Color(0xfffff2cd),
        unreadBorder: const Color(0xffc88400),
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
        selectedNavigationBackground: const Color(0x33E52521),
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
        completed: const Color(0xffE0D9BA),
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
        statusBackground: const Color(0x1a187a52),
        statusForeground: const Color(0xff17201b),
        statusBorder: const Color(0xffc8cec7),
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
