import 'package:flutter/material.dart';

import 'app_config.dart';

/// Spacing values used across the app, so layouts stay consistent.
abstract final class AppSpacing {
  static const small = 8.0;
  static const medium = 16.0;
  static const large = 24.0;
  static const xlarge = 32.0;
}

/// The neutral palette of design C2 ("Soft Rooms, revised"): stone greys, no green.
/// The brand accent comes from [AppConfig.accentColor].
abstract final class AppPalette {
  static const background = Color(0xFFEBEAE7); // window background, room list
  static const panel = Color(0xFFF7F7F5); // chat area, selected room
  static const card = Color(0xFFFFFFFF); // other people's messages, inputs
  static const line = Color(0xFFD3D1CC); // dividers between sections
  static const lineSoft = Color(0xFFE0DED9); // borders inside a section
  static const ink = Color(0xFF1D1C1F); // main text
  static const muted = Color(
    0xFF55534E,
  ); // secondary text (4.5:1+ on all grounds)
  static const charcoal = Color(0xFF2B2A2E); // your own messages
  static const onCharcoal = Color(0xFFF7F7F5);
  static const error = Color(0xFFA32626);
}

/// Colors for chat-specific parts that Material's ColorScheme has no names for.
/// Widgets read it with `Theme.of(context).extension<ChatColors>()!`.
@immutable
class ChatColors extends ThemeExtension<ChatColors> {
  const ChatColors({
    required this.ownBubble,
    required this.onOwnBubble,
    required this.otherBubble,
    required this.otherBubbleBorder,
    required this.roomList,
    required this.selectedRoom,
    required this.muted,
    required this.line,
  });

  final Color ownBubble;
  final Color onOwnBubble;
  final Color otherBubble;
  final Color otherBubbleBorder;
  final Color roomList;
  final Color selectedRoom;
  final Color muted;
  final Color line;

  @override
  ChatColors copyWith() => this;

  @override
  ChatColors lerp(ChatColors? other, double t) => other ?? this;
}

/// The app theme. Widgets get colors and text styles from `Theme.of(context)`, never from literals.
abstract final class AppTheme {
  static const _radius = 8.0;

  static ThemeData light() {
    const accent = AppConfig.accentColor;
    final scheme = const ColorScheme.light(
      primary: accent,
      onPrimary: Colors.white,
      secondary: AppPalette.charcoal,
      onSecondary: AppPalette.onCharcoal,
      surface: AppPalette.panel,
      onSurface: AppPalette.ink,
      onSurfaceVariant: AppPalette.muted,
      surfaceContainerLowest: AppPalette.card,
      surfaceContainerHighest: AppPalette.background,
      outline: AppPalette.line,
      outlineVariant: AppPalette.lineSoft,
      error: AppPalette.error,
      onError: Colors.white,
    );

    // System font (no bundled fonts, see PROJECT_PLAN.md). Headlines get their
    // character from a heavy weight and slightly tighter letter spacing.
    final base = ThemeData(colorScheme: scheme).textTheme;
    TextStyle? heavy(TextStyle? s) => s?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
      color: AppPalette.ink,
    );
    final textTheme = base.copyWith(
      displaySmall: heavy(base.displaySmall),
      headlineLarge: heavy(base.headlineLarge),
      headlineMedium: heavy(base.headlineMedium),
      headlineSmall: heavy(base.headlineSmall),
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );

    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    const buttonSize = Size(64, 44); // 44 px: comfortable click/touch target

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: AppPalette.background,
      textTheme: textTheme,
      dividerTheme: const DividerThemeData(
        color: AppPalette.line,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppPalette.panel,
        foregroundColor: AppPalette.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: AppPalette.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
          side: const BorderSide(color: AppPalette.lineSoft),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: AppPalette.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: AppPalette.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: AppPalette.ink, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: buttonSize,
          shape: rounded,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: buttonSize,
          shape: rounded,
          foregroundColor: AppPalette.ink,
          side: const BorderSide(color: AppPalette.line),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: buttonSize,
          shape: rounded,
          foregroundColor: AppPalette.ink,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: buttonSize,
          selectedBackgroundColor: AppPalette.charcoal,
          selectedForegroundColor: AppPalette.onCharcoal,
          side: const BorderSide(color: AppPalette.line),
          shape: rounded,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppPalette.charcoal,
        contentTextStyle: TextStyle(color: AppPalette.onCharcoal),
        behavior: SnackBarBehavior.floating,
      ),
      extensions: const [
        ChatColors(
          ownBubble: AppPalette.charcoal,
          onOwnBubble: AppPalette.onCharcoal,
          otherBubble: AppPalette.card,
          otherBubbleBorder: AppPalette.lineSoft,
          roomList: AppPalette.background,
          selectedRoom: AppPalette.panel,
          muted: AppPalette.muted,
          line: AppPalette.line,
        ),
      ],
    );
  }
}
