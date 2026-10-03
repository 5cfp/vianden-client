import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/app_config/app_config.dart';
import 'package:vianden_client/features/auth/auth_screen.dart';
import 'package:vianden_client/features/connect/connect_screen.dart';
import 'package:vianden_client/features/connect/server_problem_screen.dart';
import 'package:vianden_client/features/home/home_screen.dart';

import 'helpers.dart';

void main() {
  late FakeServer server;
  late MemorySessionStore store;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
  });

  /// Starts the app as if a server was chosen earlier (but nobody is logged in).
  Future<void> startAtLogin(WidgetTester tester) async {
    store.server = serverUrl;
    await pumpApp(tester, server, store);
    expect(find.byType(AuthScreen), findsOneWidget);
  }

  Future<void> logIn(WidgetTester tester, String user, String password) async {
    await type(tester, 'username', user);
    await type(tester, 'password', password);
    await tapKey(tester, 'submit');
  }

  group('first launch', () {
    testWidgets('shows the connect screen with the app name from AppConfig', (
      tester,
    ) async {
      await pumpApp(tester, server, store);
      expect(find.byType(ConnectScreen), findsOneWidget);
      expect(find.text(AppConfig.appName), findsOneWidget);
    });

    testWidgets('connecting saves the server and shows login with its name', (
      tester,
    ) async {
      await pumpApp(tester, server, store);
      await type(tester, 'server-address', serverUrl);
      await tapText(tester, 'Connect');

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text('Friends Server'), findsOneWidget);
      expect(store.server, serverUrl);
    });

    testWidgets('an unreachable server shows an error and stays on connect', (
      tester,
    ) async {
      server.down = true;
      await pumpApp(tester, server, store);
      await type(tester, 'server-address', serverUrl);
      await tapText(tester, 'Connect');

      expect(find.byType(ConnectScreen), findsOneWidget);
      expect(find.textContaining('Could not reach the server'), findsOneWidget);
      expect(store.server, isNull);
    });
  });

  group('login and register', () {
    testWidgets('login shows the home screen and saves the token', (
      tester,
    ) async {
      await startAtLogin(tester);
      await logIn(tester, 'Osama', 'owner-pass-1');

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Welcome, Osama!'), findsOneWidget);
      expect(store.token, isNotNull);
      expect(
        server.tokens[store.token],
        isNotNull,
        reason: 'the saved token is the one the server issued',
      );
    });

    testWidgets('wrong password shows an error and saves nothing', (
      tester,
    ) async {
      await startAtLogin(tester);
      await logIn(tester, 'osama', 'wrong-password');

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text('Wrong username or password.'), findsOneWidget);
      expect(store.token, isNull);
    });

    testWidgets('rate limiting shows how long to wait', (tester) async {
      server.rateLimitedFor = '5';
      await startAtLogin(tester);
      await logIn(tester, 'osama', 'owner-pass-1');

      expect(
        find.text('Too many attempts. Try again in 5 seconds.'),
        findsOneWidget,
      );
    });

    testWidgets('register with an invite logs the new user in', (tester) async {
      await startAtLogin(tester);
      await tapText(tester, 'Register');
      await type(tester, 'username', 'NewFriend');
      await type(tester, 'display-name', 'New Friend');
      await type(tester, 'password', 'new-friend-pass');
      await type(tester, 'invite-code', '  vi_good  ');
      await tapKey(tester, 'submit');

      expect(find.text('Welcome, New Friend!'), findsOneWidget);
      expect(store.token, isNotNull);
    });

    testWidgets('register with a bad invite shows the server message', (
      tester,
    ) async {
      await startAtLogin(tester);
      await tapText(tester, 'Register');
      await type(tester, 'username', 'someone');
      await type(tester, 'password', 'password123');
      await type(tester, 'invite-code', 'vi_bad');
      await tapKey(tester, 'submit');

      expect(
        find.text('Invite code is invalid, expired, or used up'),
        findsOneWidget,
      );
      expect(store.token, isNull);
    });

    testWidgets('the password field hides what is typed', (tester) async {
      await startAtLogin(tester);
      final field = tester.widget<TextField>(find.byKey(const Key('password')));
      expect(field.obscureText, isTrue);
    });
  });

  group('app restart', () {
    testWidgets('a saved valid token goes straight to home', (tester) async {
      store
        ..server = serverUrl
        ..token = server.sessionFor('friend');
      await pumpApp(tester, server, store);

      expect(find.text('Welcome, Friend!'), findsOneWidget);
      final me = server.called('GET', '/api/v1/me').single;
      expect(me.headers['Authorization'], 'Bearer ${store.token}');
    });

    testWidgets('a revoked token is deleted and login is shown', (
      tester,
    ) async {
      store
        ..server = serverUrl
        ..token = 'vs_revoked_long_ago';
      await pumpApp(tester, server, store);

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(store.token, isNull);
    });

    testWidgets('server down keeps the token and offers retry', (tester) async {
      store
        ..server = serverUrl
        ..token = server.sessionFor('friend');
      server.down = true;
      await pumpApp(tester, server, store);

      expect(find.byType(ServerProblemScreen), findsOneWidget);
      expect(
        store.token,
        isNotNull,
        reason: 'a network problem must not log the user out',
      );

      server.down = false;
      await tapKey(tester, 'retry');
      expect(find.text('Welcome, Friend!'), findsOneWidget);
    });

    testWidgets('an incompatible server version is reported', (tester) async {
      store.server = serverUrl;
      server.protocolVersion = 2;
      await pumpApp(tester, server, store);

      expect(find.byType(ServerProblemScreen), findsOneWidget);
      expect(find.textContaining('newer version of the app'), findsOneWidget);
    });
  });

  group('logged in', () {
    testWidgets(
      'logout revokes the session on the server and forgets the token',
      (tester) async {
        final token = server.sessionFor('friend');
        store
          ..server = serverUrl
          ..token = token;
        await pumpApp(tester, server, store);

        await tapKey(tester, 'logout');

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(store.token, isNull);
        expect(
          server.tokens.containsKey(token),
          isFalse,
          reason: 'server-side session revoked',
        );
        expect(
          store.server,
          serverUrl,
          reason: 'the server is still remembered',
        );
      },
    );

    testWidgets('the owner can create an invite code', (tester) async {
      store
        ..server = serverUrl
        ..token = server.sessionFor('osama');
      await pumpApp(tester, server, store);

      await tapKey(tester, 'create-invite');

      expect(find.text('vi_brand_new_code'), findsOneWidget);
      expect(find.textContaining('shown only once'), findsOneWidget);
    });

    testWidgets('a member does not see the invite button', (tester) async {
      store
        ..server = serverUrl
        ..token = server.sessionFor('friend');
      await pumpApp(tester, server, store);

      expect(find.byKey(const Key('create-invite')), findsNothing);
    });

    testWidgets(
      'a session revoked elsewhere returns to login on the next request',
      (tester) async {
        final token = server.sessionFor('osama');
        store
          ..server = serverUrl
          ..token = token;
        await pumpApp(tester, server, store);

        server.tokens.remove(token); // e.g. logged out from another device
        await tapKey(tester, 'create-invite');

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(store.token, isNull);
      },
    );

    testWidgets('changing server forgets server and token', (tester) async {
      await startAtLogin(tester);
      await tapText(tester, 'Use a different server');

      expect(find.byType(ConnectScreen), findsOneWidget);
      expect(store.server, isNull);
      expect(store.token, isNull);
    });
  });
}
