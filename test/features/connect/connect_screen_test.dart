import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vianden_client/app_config/app_config.dart';
import 'package:vianden_client/core/server_info.dart';
import 'package:vianden_client/features/connect/connect_screen.dart';

Widget screenWith(http.Client client) =>
    MaterialApp(home: ConnectScreen(httpClient: client));

void main() {
  testWidgets('shows the app name from AppConfig', (tester) async {
    await tester.pumpWidget(
      screenWith(MockClient((_) async => http.Response('', 500))),
    );
    expect(find.text(AppConfig.appName), findsOneWidget);
  });

  testWidgets('connects and shows the server name', (tester) async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'name': 'Friends Server',
          'version': '0.1.0',
          'protocol_version': supportedProtocolVersion,
        }),
        200,
      ),
    );
    await tester.pumpWidget(screenWith(client));

    await tester.enterText(
      find.byKey(const Key('server-address')),
      'http://127.0.0.1:8080',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Connected to Friends Server'), findsOneWidget);
  });

  testWidgets('shows an error for an invalid address', (tester) async {
    await tester.pumpWidget(
      screenWith(MockClient((_) async => http.Response('', 500))),
    );

    await tester.tap(find.text('Connect')); // empty address
    await tester.pumpAndSettle();

    expect(find.text('Enter a server address.'), findsOneWidget);
  });
}
