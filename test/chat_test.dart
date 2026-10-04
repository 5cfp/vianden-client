import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/features/auth/auth_screen.dart';
import 'package:vianden_client/features/chat/time_format.dart';

import 'helpers.dart';

void main() {
  late FakeServer server;
  late MemorySessionStore store;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
  });

  /// The text of the room title in the chat header.
  String roomTitle(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('room-title'))).data!;

  group('rooms', () {
    testWidgets('opens the first room and shows the room list with previews', (
      tester,
    ) async {
      server.channels.add(FakeChannel(2, 'Games'));
      server.post(1, 'friend', 'see you at nine');
      await pumpLoggedIn(tester, server, store, 'osama');

      expect(
        find.text('Friends Server'),
        findsOneWidget,
      ); // server name, top left
      expect(roomTitle(tester), 'General');
      expect(
        find.text('Friend: see you at nine'),
        findsOneWidget,
      ); // preview in the list
      expect(find.text('No messages yet'), findsOneWidget); // Games has none
    });

    testWidgets('switching rooms loads that room', (tester) async {
      server.channels.add(FakeChannel(2, 'Games', 'Who is online?'));
      server.post(2, 'friend', 'gg');
      await pumpLoggedIn(tester, server, store, 'friend');

      await tapKey(tester, 'room-2');

      expect(roomTitle(tester), 'Games');
      expect(find.text('Who is online?'), findsWidgets);
      expect(find.text('gg'), findsOneWidget);
    });

    testWidgets('an empty room invites the first message', (tester) async {
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(const Key('empty-room')), findsOneWidget);
    });
  });

  group('messages', () {
    testWidgets('own messages and others are shown, with names and times', (
      tester,
    ) async {
      final at = DateTime.now().subtract(const Duration(minutes: 30));
      server.post(1, 'friend', 'hello osama', at: at);
      server.post(
        1,
        'osama',
        'hi friend',
        at: at.add(const Duration(minutes: 1)),
      );
      await pumpLoggedIn(tester, server, store, 'osama');

      expect(find.text('hello osama'), findsOneWidget);
      expect(find.text('hi friend'), findsOneWidget);
      expect(
        find.textContaining('Friend'),
        findsWidgets,
      ); // the other person's name line
      expect(find.textContaining(hourMinute(at)), findsWidgets);
      expect(find.text('Today'), findsOneWidget); // day separator
    });

    testWidgets('sending a message shows it and clears the input', (
      tester,
    ) async {
      await pumpLoggedIn(tester, server, store, 'friend');

      await type(tester, 'composer', 'my first message');
      await tapKey(tester, 'send');

      expect(find.text('my first message'), findsOneWidget);
      expect(server.messages.single.content, 'my first message');
      expect(server.messages.single.author!.username, 'friend');
      final field = tester.widget<TextField>(find.byKey(const Key('composer')));
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('Enter sends, Shift+Enter does not', (tester) async {
      await pumpLoggedIn(tester, server, store, 'friend');
      await tester.tap(find.byKey(const Key('composer')));
      await type(tester, 'composer', 'line one');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(server.messages, isEmpty, reason: 'Shift+Enter must not send');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(server.messages.single.content, 'line one');
    });

    testWidgets('empty or blank messages are not sent', (tester) async {
      await pumpLoggedIn(tester, server, store, 'friend');
      await type(tester, 'composer', '   ');
      await tapKey(tester, 'send');
      expect(server.called('POST', '/api/v1/channels/1/messages'), isEmpty);
    });

    testWidgets('a refused message keeps its text and shows why', (
      tester,
    ) async {
      server.sendRateLimitedFor = '3';
      await pumpLoggedIn(tester, server, store, 'friend');

      await type(tester, 'composer', 'please keep me');
      await tapKey(tester, 'send');

      expect(
        find.text('Too many attempts. Try again in 3 seconds.'),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(find.byKey(const Key('composer')));
      expect(field.controller!.text, 'please keep me');
    });

    testWidgets('message text is shown literally, never as markup', (
      tester,
    ) async {
      server.post(1, 'friend', '<b>not bold</b> [link](http://evil.example)');
      await pumpLoggedIn(tester, server, store, 'osama');
      expect(
        find.text('<b>not bold</b> [link](http://evil.example)'),
        findsOneWidget,
      );
    });

    testWidgets('messages from others appear instantly', (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');
      server.postLive(1, 'friend', 'new while you were away');
      await tester.pumpAndSettle();

      expect(find.text('new while you were away'), findsOneWidget);
      expect(
        find.text('Friend: new while you were away'),
        findsOneWidget,
      ); // preview updated too
    });

    testWidgets('scrolling up loads older messages', (tester) async {
      final start = DateTime.now().subtract(const Duration(hours: 3));
      for (var i = 1; i <= 120; i++) {
        server.post(
          1,
          'friend',
          'message $i',
          at: start.add(Duration(seconds: i)),
        );
      }
      await pumpLoggedIn(tester, server, store, 'osama');

      expect(
        find.text('message 120'),
        findsOneWidget,
      ); // newest is visible at the bottom
      final firstLoad = server
          .called('GET', '/api/v1/channels/1/messages')
          .length;

      // Scroll all the way up, repeatedly, until the very first message appears.
      for (
        var i = 0;
        i < 20 && find.text('message 1').evaluate().isEmpty;
        i++
      ) {
        await tester.drag(
          find.byKey(const Key('messages')),
          const Offset(0, 3000),
        );
        await tester.pumpAndSettle();
      }

      expect(find.text('message 1'), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('messages')),
        const Offset(0, 3000),
      );
      await tester.pumpAndSettle();
      expect(find.text('This is the start of the room.'), findsOneWidget);
      final pages = server
          .called('GET', '/api/v1/channels/1/messages')
          .skip(firstLoad)
          .toList();
      expect(pages, isNotEmpty);
      expect(
        pages.first.url.queryParameters['before'],
        isNotNull,
        reason: 'older pages use "before"',
      );
    });

    testWidgets('a deleted account shows as "Deleted user"', (tester) async {
      server.messages.add(
        FakeMessage(99, 1, null, 'ghost message', DateTime.now()),
      );
      await pumpLoggedIn(tester, server, store, 'osama');
      expect(find.textContaining('Deleted user'), findsOneWidget);
    });

    testWidgets('an expired session while sending goes back to login', (
      tester,
    ) async {
      final token = server.sessionFor('friend');
      store
        ..server = serverUrl
        ..token = token;
      await pumpApp(tester, server, store);

      server.tokens.remove(token);
      await type(tester, 'composer', 'hello?');
      await tapKey(tester, 'send');

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(store.token, isNull);
    });
  });

  group('owner room tools', () {
    testWidgets('owner creates a room and it opens', (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');

      await tapKey(tester, 'new-room');
      await type(tester, 'room-name', 'Homework');
      await type(tester, 'room-topic', 'Due dates and help');
      await tapKey(tester, 'room-save');

      expect(server.channels.map((c) => c.name), contains('Homework'));
      expect(roomTitle(tester), 'Homework');
    });

    testWidgets('a taken name is reported inside the dialog', (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');

      await tapKey(tester, 'new-room');
      await type(tester, 'room-name', 'general');
      await tapKey(tester, 'room-save');

      expect(
        find.text('A channel with this name already exists'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('room-name')),
        findsOneWidget,
        reason: 'dialog stays open',
      );
    });

    testWidgets('owner renames a room', (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');

      await tapKey(tester, 'room-menu');
      await tapText(tester, 'Edit room');
      await type(tester, 'room-name', 'Lobby');
      await tapKey(tester, 'room-save');

      expect(server.channels.single.name, 'Lobby');
      expect(roomTitle(tester), 'Lobby');
    });

    testWidgets('owner deletes a room after confirming', (tester) async {
      server.channels.add(FakeChannel(2, 'Games'));
      await pumpLoggedIn(tester, server, store, 'osama');
      await tapKey(tester, 'room-2');

      await tapKey(tester, 'room-menu');
      await tapText(tester, 'Delete room');
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await tapKey(tester, 'confirm-delete');

      expect(server.channels.map((c) => c.name), ['General']);
      expect(
        roomTitle(tester),
        'General',
        reason: 'falls back to the first room',
      );
    });

    testWidgets('members do not see room tools', (tester) async {
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(const Key('new-room')), findsNothing);
      expect(find.byKey(const Key('room-menu')), findsNothing);
    });
  });

  group('layout', () {
    testWidgets(
      'header buttons sit at the right edge, even with a short room name',
      (tester) async {
        await pumpLoggedIn(
          tester,
          server,
          store,
          'osama',
        ); // window is 1280 px wide
        expect(
          tester.getTopRight(find.byKey(const Key('room-menu'))).dx,
          greaterThan(1220),
        );
      },
    );

    testWidgets('the day separator is centered in the chat', (tester) async {
      server.post(1, 'friend', 'hi');
      await pumpLoggedIn(tester, server, store, 'osama');
      final label = tester.getCenter(find.text('Today'));
      final chat = tester.getRect(find.byKey(const Key('messages')));
      expect((label.dx - chat.center.dx).abs(), lessThan(2));
    });
  });

  group('time formatting', () {
    final now = DateTime(2026, 10, 4, 18, 30);

    test('day labels', () {
      expect(dayLabel(DateTime(2026, 10, 4, 9), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 10, 3, 23), now: now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 9, 28), now: now), '28 Sep 2026');
    });

    test('room list times', () {
      expect(shortWhen(DateTime(2026, 10, 4, 7, 5), now: now), '07:05');
      expect(shortWhen(DateTime(2026, 10, 1, 12), now: now), 'Thu');
      expect(shortWhen(DateTime(2026, 9, 1), now: now), '1 Sep');
    });
  });
}
