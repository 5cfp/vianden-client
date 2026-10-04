/// The ONE place for branding and app-wide settings.
///
/// Widgets must read the app name, logo, colors, and default server address
/// from here (or from the theme built from it), never from their own literals.
/// In M10 these values will come from a branding file (build time) and from
/// the server (runtime).
library;

import 'package:flutter/material.dart';

abstract final class AppConfig {
  /// Name shown to users (window title, headers). Final public name not decided yet.
  static const appName = 'Vianden';

  /// Server address prefilled on the connect screen.
  /// Empty in the official client; a branded build can preset it.
  static const defaultServerAddress = '';

  /// Shown on the About page. Keep in sync with "version:" in pubspec.yaml.
  static const appVersion = '0.1.0';

  /// Copyright line on the About page.
  static const legalese = '© 2026 Osama Alamri · MIT License';

  /// Brand accent: buttons, selection marks, unread counts. White text must be readable on it.
  static const accentColor = Color(0xFFB8441A); // burnt orange (design C2)
}
