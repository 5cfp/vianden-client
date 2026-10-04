import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/core/certificate_trust.dart';
import 'package:vianden_client/features/auth/auth_screen.dart';
import 'package:vianden_client/features/connect/connect_screen.dart';
import 'package:vianden_client/features/connect/server_problem_screen.dart';

import 'helpers.dart';

final certA = utf8.encode('certificate A');
final certB = utf8.encode('certificate B (an attacker?)');
const httpsServer = 'https://chat.example.com:8443';

void main() {
  group('CertificateTrust', () {
    test(
      'fingerprint format matches what the server prints (SHA-256, AB:CD:...)',
      () {
        // Same input as the Go server's test, checked against openssl.
        expect(
          fingerprintOf(utf8.encode('certificate bytes')),
          '22:69:B5:8C:43:01:2E:FC:59:B0:54:4F:87:02:B3:FD:D5:FB:A9:DA:5D:38:C8:EA:B1:93:F6:F4:8D:E6:25:56',
        );
      },
    );

    test('unknown certificates are refused and remembered for the dialog', () {
      final trust = CertificateTrust();
      expect(trust.check(certA, 'chat.example.com', 8443), isFalse);
      expect(trust.rejectedFor(Uri.parse(httpsServer)), fingerprintOf(certA));
    });

    test('a pinned certificate is accepted, a different one is not', () {
      final trust = CertificateTrust()
        ..trust(Uri.parse(httpsServer), fingerprintOf(certA));
      expect(trust.check(certA, 'chat.example.com', 8443), isTrue);
      expect(trust.check(certB, 'chat.example.com', 8443), isFalse);
    });

    test('a pin only counts for its own host and port', () {
      final trust = CertificateTrust()
        ..trust(Uri.parse(httpsServer), fingerprintOf(certA));
      expect(trust.check(certA, 'other.example.com', 8443), isFalse);
      expect(trust.check(certA, 'chat.example.com', 443), isFalse);
      expect(
        trust.check(certA, 'CHAT.example.com', 8443),
        isTrue,
        reason: 'host names ignore case',
      );
    });
  });

  group('connecting to a self-signed server', () {
    late FakeServer server;
    late MemorySessionStore store;

    setUp(() {
      server = FakeServer()..selfSignedCert = certA;
      store = MemorySessionStore();
    });

    // While the dialog is open the Connect button's spinner keeps animating behind it,
    // so these steps wait a fixed time instead of "until nothing moves" (pumpAndSettle).
    Future<void> tapAndWait(WidgetTester tester, Finder f) async {
      await tester.tap(f);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> connect(WidgetTester tester) async {
      await type(tester, 'server-address', httpsServer);
      await tapAndWait(tester, find.text('Connect'));
    }

    testWidgets(
      'first time: shows the fingerprint; trusting it connects and saves the pin',
      (tester) async {
        await pumpApp(tester, server, store);
        await connect(tester);

        expect(find.text('Verify this server'), findsOneWidget);
        final shown = tester
            .widget<SelectableText>(find.byKey(const Key('fingerprint')))
            .data!;
        expect(shown.replaceAll('\n', ':'), fingerprintOf(certA));

        await tapKey(tester, 'trust-certificate');

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(store.pins, {'chat.example.com:8443': fingerprintOf(certA)});
      },
    );

    testWidgets('cancelling does not connect and saves nothing', (
      tester,
    ) async {
      await pumpApp(tester, server, store);
      await connect(tester);
      await tapText(tester, 'Cancel');

      expect(find.byType(ConnectScreen), findsOneWidget);
      expect(
        find.text('Not connected: the certificate was not trusted.'),
        findsOneWidget,
      );
      expect(store.pins, isEmpty);
      expect(store.server, isNull);
    });

    testWidgets('a pinned certificate is accepted silently on the next start', (
      tester,
    ) async {
      store
        ..server = httpsServer
        ..pins = {'chat.example.com:8443': fingerprintOf(certA)};
      await pumpApp(tester, server, store);

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text('Verify this server'), findsNothing);
    });

    testWidgets('a CHANGED certificate at startup is reported as a warning', (
      tester,
    ) async {
      store
        ..server = httpsServer
        ..token = server.sessionFor('osama')
        ..pins = {'chat.example.com:8443': fingerprintOf(certA)};
      server.selfSignedCert = certB; // e.g. an attacker in the middle
      await pumpApp(tester, server, store);

      expect(find.byType(ServerProblemScreen), findsOneWidget);
      expect(find.textContaining('CHANGED'), findsOneWidget);
      expect(find.textContaining(fingerprintOf(certB)), findsOneWidget);
      expect(
        server.called('GET', '/api/v1/me'),
        isEmpty,
        reason: 'the token must not be sent to an untrusted server',
      );
    });

    testWidgets(
      'a changed certificate needs an explicit confirmation to trust',
      (tester) async {
        store.pins = {'chat.example.com:8443': fingerprintOf(certA)};
        server.selfSignedCert = certB;
        await pumpApp(tester, server, store);
        await connect(tester);

        expect(find.text('Certificate changed!'), findsOneWidget);
        final trustButton = tester.widget<TextButton>(
          find.byKey(const Key('trust-certificate')),
        );
        expect(
          trustButton.onPressed,
          isNull,
          reason: 'disabled until the box is ticked',
        );

        await tapKey(tester, 'reject-certificate');
        expect(
          store.pins['chat.example.com:8443'],
          fingerprintOf(certA),
          reason: 'old pin kept',
        );

        await connect(tester);
        await tapAndWait(tester, find.byKey(const Key('confirm-change')));
        await tapKey(tester, 'trust-certificate');
        expect(store.pins['chat.example.com:8443'], fingerprintOf(certB));
        expect(find.byType(AuthScreen), findsOneWidget);
      },
    );

    testWidgets(
      'servers with a normal (trusted) certificate never show the dialog',
      (tester) async {
        server.selfSignedCert = null; // like a Let's Encrypt server
        await pumpApp(tester, server, store);
        await connect(tester);
        expect(find.byType(AuthScreen), findsOneWidget);
        expect(store.pins, isEmpty);
      },
    );
  });

  testWidgets('About & licenses opens from the connect screen', (tester) async {
    await pumpApp(tester, FakeServer(), MemorySessionStore());
    await tapKey(tester, 'about');
    expect(find.text('Licenses'), findsWidgets);
  });
}
