import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/app_config/app_config.dart';
import 'package:vianden_client/features/auth/auth_screen.dart';

import 'helpers.dart';

void main() {
  late FakeServer server;
  late MemorySessionStore store;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
  });

  String typingText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('typing'))).data!;

  testWidgets('connects with the session token after login', (tester) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    expect(server.connections, hasLength(1));
    expect(server.connections.single.token, store.token);
  });

  testWidgets(
    'a message from someone else appears instantly, with its preview',
    (tester) async {
      server.channels.add(FakeChannel(2, 'Games'));
      await pumpLoggedIn(tester, server, store, 'osama');

      server.postLive(1, 'friend', 'hello live');
      server.postLive(2, 'friend', 'in another room');
      await tester.pumpAndSettle();

      expect(
        find.text('hello live'),
        findsOneWidget,
      ); // open room: shown in the chat
      expect(
        find.text('Friend: in another room'),
        findsOneWidget,
      ); // other room: preview only
      expect(find.text('in another room'), findsNothing);
    },
  );

  testWidgets('my own message is not shown twice (REST answer + live event)', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    await type(tester, 'composer', 'only once');
    await tapKey(tester, 'send');
    expect(find.text('only once'), findsOneWidget);
  });

  testWidgets('typing in the composer tells others, at most every 3 seconds', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    final conn = server.connections.single;

    await type(tester, 'composer', 'h');
    await type(tester, 'composer', 'he');
    await type(tester, 'composer', 'hel');
    expect(conn.sent.where((m) => m['type'] == 'typing'), hasLength(1));
    expect(conn.sent.first['data'], {'channel_id': 1});

    await tester.pump(const Duration(seconds: 3));
    await type(tester, 'composer', 'hell');
    expect(conn.sent.where((m) => m['type'] == 'typing'), hasLength(2));
  });

  testWidgets('shows who is typing, and hides it after 5 seconds', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    final conn = server.connections.single;

    conn.push('typing.started', {
      'channel_id': 1,
      'user': {'id': 2, 'username': 'friend', 'display_name': 'Friend'},
    });
    await tester.pump();
    await tester.pump();
    expect(typingText(tester), 'Friend is typing…');

    conn.push('typing.started', {
      'channel_id': 1,
      'user': {'id': 3, 'username': 'sara', 'display_name': 'Sara'},
    });
    await tester.pump();
    await tester.pump();
    expect(typingText(tester), 'Friend and Sara are typing…');

    await tester.pump(const Duration(seconds: 6));
    expect(typingText(tester), '');
  });

  testWidgets('typing in another room is not shown here', (tester) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    server.connections.single.push('typing.started', {
      'channel_id': 99,
      'user': {'id': 2, 'username': 'friend', 'display_name': 'Friend'},
    });
    await tester.pump();
    await tester.pump();
    expect(typingText(tester), '');
  });

  testWidgets('a new message ends that person\'s typing indicator', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    server.connections.single.push('typing.started', {
      'channel_id': 1,
      'user': {'id': 2, 'username': 'friend', 'display_name': 'Friend'},
    });
    await tester.pump();
    await tester.pump();
    server.postLive(1, 'friend', 'done typing');
    await tester.pump();
    await tester.pump();
    expect(typingText(tester), '');
  });

  testWidgets('online count follows presence events', (tester) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    expect(find.text('1 online'), findsOneWidget); // yourself

    final friend = {'id': 2, 'username': 'friend', 'display_name': 'Friend'};
    server.pushAll('presence.updated', {'user': friend, 'online': true});
    await tester.pump();
    await tester.pump();
    expect(find.text('2 online'), findsOneWidget);

    server.pushAll('presence.updated', {'user': friend, 'online': false});
    await tester.pump();
    await tester.pump();
    expect(find.text('1 online'), findsOneWidget);
  });

  testWidgets('rooms created by the owner appear for everyone', (tester) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    server.channels.add(FakeChannel(5, 'Movies'));
    server.pushAll('channel.created', {
      'id': 5,
      'name': 'Movies',
      'topic': '',
      'type': 'text',
      'position': 1,
      'last_message': null,
    });
    await tester.pumpAndSettle();
    expect(find.text('Movies'), findsOneWidget);
  });

  testWidgets(
    'a dropped connection shows "Reconnecting", reconnects and reloads',
    (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');
      final roomLoads = server.called('GET', '/api/v1/channels').length;

      server.dropAll();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('reconnecting')), findsOneWidget);
      expect(
        find.text('${AppConfig.appName} · connecting…'),
        findsOneWidget,
      ); // room list status

      // Messages sent while we were away...
      server.post(1, 'friend', 'sent while you were offline');

      // ...are loaded after the automatic reconnect (first retry after 1-2 s).
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reconnecting')), findsNothing);
      expect(server.connections, hasLength(1));
      expect(
        server.called('GET', '/api/v1/channels').length,
        greaterThan(roomLoads),
      );
      expect(find.text('sent while you were offline'), findsOneWidget);
    },
  );

  testWidgets('reconnect attempts slow down while the server is down', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    server.down = true;
    server.dropAll();
    await tester.pump();
    await tester.pump();

    // Waits of about 1, 2, 4, 8 s: in 16 seconds, at most 5 attempts (not one per frame).
    await tester.pump(const Duration(seconds: 16));
    await tester.pump(const Duration(seconds: 1));
    expect(server.connectAttempts, inInclusiveRange(3, 6));

    server.down = false;
    await tester.pump(const Duration(seconds: 17));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reconnecting')), findsNothing);
  });

  testWidgets(
    'logged out elsewhere (close code 4001) goes to login and stops reconnecting',
    (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');
      server.endSession(store.token!);
      await tester.pumpAndSettle();

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(store.token, isNull);
      final attempts = server.connectAttempts;
      await tester.pump(const Duration(seconds: 40));
      expect(
        server.connectAttempts,
        attempts,
        reason: 'no reconnect after the session ended',
      );
    },
  );

  testWidgets('logging out closes the live connection', (tester) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    await accountMenu(tester, 'Log out');
    expect(server.connections, isEmpty);
  });

  testWidgets('a revoked token found while reconnecting goes to login', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    server.tokens.remove(store.token); // revoked while the network was down
    server.dropAll();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(AuthScreen), findsOneWidget);
  });

  testWidgets('unknown and malformed events are ignored', (tester) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    final conn = server.connections.single;
    conn.push('something.new', {'x': 1});
    conn.push('message.created', {'id': 'not a number'});
    await tester.pump();
    await tester.pump();
    server.postLive(1, 'friend', 'still working');
    await tester.pumpAndSettle();
    expect(find.text('still working'), findsOneWidget);
  });
}
