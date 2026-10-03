import 'package:flutter/material.dart';

import 'app_config.dart';

/// Spacing values used across the app, so layouts stay consistent.
abstract final class AppSpacing {
  static const small = 8.0;
  static const medium = 16.0;
  static const large = 24.0;
}

/// The app theme. Widgets get colors from `Theme.of(context)`, never from literals.
abstract final class AppTheme {
  static ThemeData light() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: AppConfig.seedColor),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );
  }
}
