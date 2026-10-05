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

  /// App version. MUST equal "version:" in pubspec.yaml without the "+build" part
  /// (a test checks this). A "-alpha" or "-beta" suffix marks a pre-release: the app
  /// then shows a badge and a short warning (see widgets/release_badge.dart).
  static const appVersion = '0.3.0-alpha.3';

  /// "ALPHA", "ALPHA 3", "BETA", ... for pre-releases; null for normal releases.
  static String? get releaseStage {
    final dash = appVersion.indexOf('-');
    return dash < 0
        ? null
        : appVersion.substring(dash + 1).toUpperCase().replaceAll('.', ' ');
  }

  /// What a pre-release means for testers (shown under the badge).
  static const preReleaseNotice =
      'Test version: expect bugs. Messages and accounts may be reset.';

  /// Copyright line on the About page.
  static const legalese = '© 2026 Osama Alamri · MIT License';

  /// Brand accent: buttons, selection marks, unread counts. White text must be readable on it.
  static const accentColor = Color(0xFFB8441A); // burnt orange (design C2)
}
