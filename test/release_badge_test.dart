import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/app_config/app_config.dart';

import 'helpers.dart';

void main() {
  test(
    'AppConfig.appVersion matches pubspec.yaml (without the +build part)',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec)!.group(1)!;
      expect(AppConfig.appVersion, version.split('+').first);
    },
  );

  test('the release stage comes from the version suffix', () {
    expect(AppConfig.appVersion.contains('-'), AppConfig.releaseStage != null);
    if (AppConfig.appVersion == '0.3.0-alpha.3') {
      expect(AppConfig.releaseStage, 'ALPHA 3');
    }
  });

  String badgeText(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const Key('release-badge')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  testWidgets('connect screen shows the badge and the notice', (tester) async {
    await pumpApp(tester, FakeServer(), MemorySessionStore());
    expect(
      badgeText(tester),
      '${AppConfig.releaseStage} · v${AppConfig.appVersion}',
    );
    expect(find.text(AppConfig.preReleaseNotice), findsOneWidget);
  });

  testWidgets('login screen shows the badge and the notice', (tester) async {
    await pumpApp(
      tester,
      FakeServer(),
      MemorySessionStore()..server = serverUrl,
    );
    expect(find.byKey(const Key('release-badge')), findsOneWidget);
    expect(find.byKey(const Key('release-notice')), findsOneWidget);
  });

  testWidgets('chat screen shows the badge; the notice is in its tooltip', (
    tester,
  ) async {
    final server = FakeServer();
    await pumpLoggedIn(tester, server, MemorySessionStore(), 'osama');
    expect(find.byKey(const Key('release-badge')), findsOneWidget);
    expect(find.byKey(const Key('release-notice')), findsNothing);
    expect(find.byTooltip(AppConfig.preReleaseNotice), findsOneWidget);
  });
}
