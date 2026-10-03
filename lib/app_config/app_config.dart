/// The ONE place for branding and app-wide settings.
///
/// Widgets must read the app name, logo, colors, and default server address
/// from here, never from their own literals. In M10 these values will come from
/// a branding file (build time) and from the server (runtime).
library;

import 'package:flutter/material.dart';

abstract final class AppConfig {
  /// Name shown to users (window title, headers). Final public name not decided yet.
  static const appName = 'Vianden';

  /// Server address prefilled on the connect screen.
  /// Empty in the official client; a branded build can preset it.
  static const defaultServerAddress = '';

  /// Main brand color. The whole color scheme is generated from it.
  /// Placeholder until the design direction is chosen in M2.
  static const seedColor = Color(0xFF3D5AFE);
}
