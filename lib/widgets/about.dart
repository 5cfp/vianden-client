import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_config/app_config.dart';

/// Adds this app's own license (MIT) to the license page, next to the licenses of every
/// package Flutter bundles automatically. Call once at startup.
void registerAppLicense() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      AppConfig.appName,
    ], await rootBundle.loadString('LICENSE'));
    // The native WebRTC library used for voice is not a Dart package, so Flutter does not
    // list it by itself.
    yield LicenseEntryWithLineBreaks([
      'WebRTC (libwebrtc)',
    ], await rootBundle.loadString('licenses/webrtc.txt'));
  });
}

/// Opens the "About & licenses" page: app name, version, and all open-source licenses.
void showAbout(BuildContext context) => showLicensePage(
  context: context,
  applicationName: AppConfig.appName,
  applicationVersion: AppConfig.appVersion,
  applicationLegalese: AppConfig.legalese,
);
