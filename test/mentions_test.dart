import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/core/models.dart';
import 'package:vianden_client/core/permissions.dart';
import 'package:vianden_client/features/chat/message_view.dart';

import 'helpers.dart';

/// M6 step 2: @mentions and unread indicators.
void main() {
  late FakeServer server;
  late MemorySessionStore store;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
    server.channels.add(FakeChannel(2, 'Games'));
  });

  String badge(WidgetTester tester, int roomId) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(Key('unread-$roomId')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  /// Everything older is already read (like the migration does for existing users).
  void readEverything() {
    for (final u in server.users) {
      for (final c in server.channels) {
        server.readStates[(u.id, c.id)] = server.messages.length;
      }
    }
  }

  group('mention highlighting', () {
    test('only mentions the server confirmed are styled', () {
      final m = Message(
        id: 1,
        channelId: 1,
        author: null,
        content: 'hi @Friend and @ghost, mail x@friend.com',
        createdAt: DateTime(2026),
        mentions: const [
          Author(id: 2, username: 'friend', displayName: 'Friend'),
        ],
      );
      const bold = TextStyle(fontWeight: FontWeight.w700);
      final spans = mentionSpans(m, bold);
      expect(spans.map((s) => s.text), [
        'hi ',
        '@Friend',
        ' and @ghost, mail x@friend.com',
      ]);
      expect(spans[1].style, bold);
      expect(spans[0].style, isNull);
    });

    test('a message knows whether it pings someone', () {
      final m = Message(
        id: 1,
        channelId: 1,
        author: null,
        content: '@everyone',
        createdAt: DateTime(2026),
        mentionsEveryone: true,
      );
      expect(m.mentionsUser(42), isTrue);
    });
  });

  group('unread', () {
    testWidgets('badges for other rooms; opening a room clears them', (
      tester,
    ) async {
      server.post(1, 'osama', 'old news');
      readEverything();
      server.post(2, 'osama', 'anyone?');
      server.post(2, 'osama', 'hey @friend');
      await pumpLoggedIn(tester, server, store, 'friend');

      expect(find.byKey(const Key('unread-1')), findsNothing); // the open room
      expect(badge(tester, 2), '@1'); // 2 unread, 1 mentions me: show the ping

      await tapKey(tester, 'room-2');
      expect(find.byKey(const Key('unread-2')), findsNothing);
      expect(server.readStates[(2, 2)], server.messages.last.id);
      // The "New" line sits above the first message that was unread.
      expect(find.byKey(const Key('new-divider')), findsOneWidget);
    });

    testWidgets('a live message in another room adds to its badge', (
      tester,
    ) async {
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(const Key('unread-2')), findsNothing);

      server.postLive(2, 'osama', 'game night?');
      await tester.pumpAndSettle();
      expect(badge(tester, 2), '1');

      server.postLive(2, 'osama', '@friend you in?');
      await tester.pumpAndSettle();
      expect(badge(tester, 2), '@1');

      // A message in the open room is read at once: no badge, and the server knows.
      final here = server.postLive(1, 'osama', 'hello');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unread-1')), findsNothing);
      expect(server.readStates[(2, 1)], here.id);
    });

    testWidgets('reading on another device clears the badge here', (
      tester,
    ) async {
      final m = server.post(2, 'osama', 'unread');
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(badge(tester, 2), '1');

      server.pushAll('channel.read', {'channel_id': 2, 'last_read_id': m.id});
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unread-2')), findsNothing);
    });

    testWidgets('a reply pings the original author', (tester) async {
      final q = server.post(2, 'friend', 'who wants pizza');
      readEverything();
      server.post(2, 'osama', 'me', replyTo: q);
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(badge(tester, 2), '@1');
    });

    testWidgets('100 or more shows 99+', (tester) async {
      for (var i = 0; i < 105; i++) {
        server.post(2, 'osama', 'spam $i');
      }
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(badge(tester, 2), '99+');
    });
  });

  group('@ autocomplete', () {
    testWidgets('type @ and pick a person with Tab', (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');

      await type(tester, 'composer', 'hi @fr');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mention-friend')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('hi @friend '), findsOneWidget);
      expect(find.byKey(const Key('mention-suggestions')), findsNothing);

      await tapKey(tester, 'send');
      final sent = server.messages.last;
      expect(sent.mentions.map((u) => u.username), ['friend']);
    });

    testWidgets('@everyone is only offered to moderators and up', (
      tester,
    ) async {
      await pumpLoggedIn(tester, server, store, 'friend');
      await type(tester, 'composer', '@ev');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mention-everyone')), findsNothing);
    });

    testWidgets('owners get @everyone; e-mail addresses do not trigger it', (
      tester,
    ) async {
      await pumpLoggedIn(tester, server, store, 'osama');
      await type(tester, 'composer', 'mail me at me@fr');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mention-suggestions')), findsNothing);

      await type(tester, 'composer', '@ev');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mention-everyone')), findsOneWidget);
      expect(Role.owner.atLeast(Role.moderator), isTrue);
    });
  });
}
