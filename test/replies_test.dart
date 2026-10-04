import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/core/models.dart';
import 'package:vianden_client/core/permissions.dart';

import 'helpers.dart';

/// M6 step 1: replies, editing and deleting your own messages.
void main() {
  late FakeServer server;
  late MemorySessionStore store;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
  });

  /// The plain text shown in a message bubble (including "(edited)").
  String bubbleText(WidgetTester tester, int id) => tester
      .widget<SelectableText>(find.byKey(Key('message-$id')))
      .textSpan!
      .toPlainText();

  group('models', () {
    test('a reply quote is shortened like the server does', () {
      final m = Message(
        id: 1,
        channelId: 1,
        author: null,
        content: '😀' * 150,
        createdAt: DateTime(2026),
      );
      final q = ReplyQuote.of(m);
      expect(q.content.runes.length, 101); // 100 + "…"
      expect(q.content.endsWith('…'), isTrue);
    });

    test('reads edited_at and reply_to', () {
      final m = Message.fromJson({
        'id': 2,
        'channel_id': 1,
        'author': null,
        'content': 'yes',
        'created_at': '2026-10-04T18:30:00Z',
        'deleted': false,
        'edited_at': '2026-10-04T18:31:00Z',
        'reply_to': {
          'id': 1,
          'author': {'id': 1, 'username': 'osama', 'display_name': 'Osama'},
          'content': 'ok?',
          'deleted': false,
        },
      });
      expect(m.editedAt, isNotNull);
      expect(m.replyTo!.id, 1);
      expect(m.replyTo!.author!.displayName, 'Osama');
    });
  });

  group('replies', () {
    testWidgets('reply from the message actions, with a quote', (tester) async {
      final q = server.post(1, 'osama', 'pizza tonight?');
      await pumpLoggedIn(tester, server, store, 'friend');

      await tapKey(tester, 'reply-message-${q.id}');
      expect(find.byKey(const Key('reply-bar')), findsOneWidget);
      expect(find.textContaining('Replying to', findRichText: true), findsOne);

      await type(tester, 'composer', 'yes please');
      await tapKey(tester, 'send');

      final sent = server.messages.last;
      expect(sent.content, 'yes please');
      expect(sent.replyTo?.id, q.id);
      expect(find.byKey(const Key('reply-bar')), findsNothing); // back to normal
      // The new message shows the quote of the original above it.
      expect(find.byKey(Key('quote-${q.id}')), findsOneWidget);
      expect(
        find.textContaining('pizza tonight?', findRichText: true),
        findsNWidgets(2), // the original + the quote
      );
    });

    testWidgets('Esc and the X cancel a reply', (tester) async {
      final q = server.post(1, 'osama', 'hello');
      await pumpLoggedIn(tester, server, store, 'friend');

      await tapKey(tester, 'reply-message-${q.id}');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-bar')), findsNothing);

      await tapKey(tester, 'reply-message-${q.id}');
      await tapKey(tester, 'cancel-mode');
      expect(find.byKey(const Key('reply-bar')), findsNothing);

      await type(tester, 'composer', 'just a message');
      await tapKey(tester, 'send');
      expect(server.messages.last.replyTo, isNull);
    });

    testWidgets('no reply button in a read-only room', (tester) async {
      server.channels.first.sendRole = Role.moderator;
      final q = server.post(1, 'osama', 'announcement');
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(Key('reply-message-${q.id}')), findsNothing);
    });

    testWidgets('a deleted original shows in the quote', (tester) async {
      final q = server.post(1, 'osama', 'oops');
      server.post(1, 'friend', 'what?', replyTo: q);
      q
        ..deleted = true
        ..content = '';
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.text('Original message deleted'), findsOneWidget);
    });

    testWidgets('tapping a quote scrolls up to the original, loading older pages', (
      tester,
    ) async {
      final first = server.post(1, 'osama', 'the very first message');
      for (var i = 0; i < 80; i++) {
        server.post(1, 'osama', 'filler $i');
      }
      server.post(1, 'friend', 'remember this?', replyTo: first);
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(Key('message-${first.id}')), findsNothing); // not loaded

      await tapKey(tester, 'quote-${first.id}');
      await tester.pumpAndSettle();
      expect(find.byKey(Key('message-${first.id}')), findsOneWidget);
      expect(
        server.requests.where((r) => r.url.queryParameters['before'] != null),
        isNotEmpty, // it had to load the older page
      );
    });
  });

  group('editing', () {
    testWidgets('edit your own message', (tester) async {
      final mine = server.post(1, 'friend', 'helo');
      await pumpLoggedIn(tester, server, store, 'friend');

      await type(tester, 'composer', 'a draft');
      await tapKey(tester, 'edit-message-${mine.id}');
      expect(find.byKey(const Key('edit-bar')), findsOneWidget);
      expect(find.text('helo'), findsWidgets); // the old text is in the box

      await type(tester, 'composer', 'hello');
      await tapKey(tester, 'send'); // "Save"

      expect(server.messages.single.content, 'hello');
      expect(bubbleText(tester, mine.id), 'hello  (edited)');
      // The draft typed before editing is back.
      expect(find.text('a draft'), findsOneWidget);
    });

    testWidgets('no edit button on other people\'s messages', (tester) async {
      final theirs = server.post(1, 'osama', 'mine, not yours');
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(Key('edit-message-${theirs.id}')), findsNothing);
      expect(find.byKey(Key('delete-message-${theirs.id}')), findsNothing);
    });

    testWidgets('an edit arrives live and updates quotes too', (tester) async {
      final orig = server.post(1, 'osama', 'meet at 8');
      final reply = server.post(1, 'friend', 'ok', replyTo: orig);
      await pumpLoggedIn(tester, server, store, 'friend');

      orig
        ..content = 'meet at 9'
        ..editedAt = DateTime.now();
      server.pushAll('message.updated', orig.toJson());
      await tester.pumpAndSettle();

      expect(bubbleText(tester, orig.id), 'meet at 9  (edited)');
      expect(find.byKey(Key('quote-${orig.id}')), findsOneWidget);
      expect(
        find.textContaining('meet at 9', findRichText: true),
        findsNWidgets(2),
      );
      expect(reply.replyTo, same(orig));
    });
  });

  group('deleting your own', () {
    testWidgets('a member deletes their own message', (tester) async {
      final mine = server.post(1, 'friend', 'wrong room');
      await pumpLoggedIn(tester, server, store, 'friend');

      await tapKey(tester, 'delete-message-${mine.id}');
      await tapKey(tester, 'confirm-delete-message');

      expect(server.messages.single.deleted, isTrue);
      expect(find.text('Message deleted'), findsOneWidget);
    });
  });
}
