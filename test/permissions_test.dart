import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/core/models.dart';
import 'package:vianden_client/core/permissions.dart';

import 'helpers.dart';

/// M5: roles and permissions. The UI hides what a role cannot do, and moderators
/// get their tools. (The real checks happen on the server; see vianden-server tests.)
void main() {
  late FakeServer server;
  late MemorySessionStore store;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
  });

  group('models', () {
    test('roles are ordered and unknown roles become member', () {
      expect(Role.admin.above(Role.moderator), isTrue);
      expect(Role.moderator.above(Role.moderator), isFalse);
      expect(Role.parse('superuser'), Role.member);
    });

    test('user reads role and permissions; old servers send is_owner', () {
      final u = User.fromJson({
        'id': 1,
        'username': 'a',
        'display_name': 'A',
        'role': 'moderator',
        'permissions': ['delete_messages', 'kick_members'],
      });
      expect(u.role, Role.moderator);
      expect(u.can(Permission.kickMembers), isTrue);
      expect(u.can(Permission.banMembers), isFalse);

      final old = User.fromJson({
        'id': 1,
        'username': 'a',
        'display_name': 'A',
        'is_owner': true,
      });
      expect(old.isOwner, isTrue);
    });
  });

  group('members see no tools', () {
    testWidgets('no room tools, no invite, member list without actions', (
      tester,
    ) async {
      await pumpLoggedIn(tester, server, store, 'friend');

      expect(find.byKey(const Key('new-room')), findsNothing);
      expect(find.byKey(const Key('room-menu')), findsNothing);

      await tapKey(tester, 'account-menu');
      expect(find.text('Invite a friend'), findsNothing);
      await tapText(tester, 'Members');
      expect(find.text('Osama'), findsOneWidget);
      expect(find.byKey(const Key('member-menu-1')), findsNothing);
    });

    testWidgets('hidden rooms are not listed', (tester) async {
      server.channels.add(
        FakeChannel(2, 'Staff', '', Role.moderator, Role.moderator),
      );
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(const Key('room-2')), findsNothing);
    });

    testWidgets('read-only room shows a notice instead of the composer', (
      tester,
    ) async {
      server.channels.first.sendRole = Role.moderator;
      await pumpLoggedIn(tester, server, store, 'friend');

      expect(find.byKey(const Key('read-only')), findsOneWidget);
      expect(find.textContaining('Only Moderators and up'), findsOneWidget);
      expect(find.byKey(const Key('composer')), findsNothing);
    });
  });

  group('room access', () {
    testWidgets('owner creates a staff-only room', (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');

      await tapKey(tester, 'new-room');
      await type(tester, 'room-name', 'Staff');
      await tapKey(tester, 'room-view-role');
      await tapText(tester, 'Moderators and up');
      await tapKey(tester, 'room-save');

      final staff = server.channels.last;
      expect(staff.name, 'Staff');
      expect(staff.viewRole, Role.moderator);
      // "Who can write" was raised along with "who can see".
      expect(staff.sendRole, Role.moderator);
      expect(find.byKey(Key('room-private-${staff.id}')), findsOneWidget);
    });

    testWidgets('a room hidden from me disappears live', (tester) async {
      server.channels.add(FakeChannel(2, 'Games'));
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(const Key('room-2')), findsOneWidget);

      server.channels.last.viewRole = Role.moderator;
      server.channels.last.sendRole = Role.moderator;
      server.pushAll('channel.deleted', {'id': 2});
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('room-2')), findsNothing);
    });
  });

  group('deleting messages', () {
    testWidgets('moderator deletes a member message, not the owner\'s', (
      tester,
    ) async {
      server.users.add(
        FakeUser(3, 'mod', 'Mod', 'mod-pass-1', role: Role.moderator),
      );
      final bad = server.post(1, 'friend', 'something rude');
      final boss = server.post(1, 'osama', 'house rules');
      await pumpLoggedIn(tester, server, store, 'mod');

      expect(find.byKey(Key('delete-message-${boss.id}')), findsNothing);
      await tapKey(tester, 'delete-message-${bad.id}');
      await tapKey(tester, 'confirm-delete-message');

      expect(server.messages.first.deleted, isTrue);
      expect(find.text('something rude'), findsNothing);
      expect(find.byKey(Key('deleted-${bad.id}')), findsOneWidget);
      expect(find.text('Message deleted'), findsOneWidget);
    });

    testWidgets('members have no delete button', (tester) async {
      final m = server.post(1, 'osama', 'hello');
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(Key('delete-message-${m.id}')), findsNothing);
    });

    testWidgets('a deletion arrives live', (tester) async {
      final m = server.post(1, 'osama', 'oops wrong room');
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.text('oops wrong room'), findsOneWidget);

      server.messages.single
        ..deleted = true
        ..content = '';
      server.pushAll('message.deleted', {'id': m.id, 'channel_id': 1});
      await tester.pumpAndSettle();

      expect(find.text('oops wrong room'), findsNothing);
      expect(find.text('Message deleted'), findsOneWidget);
    });
  });

  group('managing members', () {
    Future<void> openMemberMenu(WidgetTester tester, int id) async {
      await accountMenu(tester, 'Members');
      await tapKey(tester, 'member-menu-$id');
    }

    testWidgets('owner makes a member moderator', (tester) async {
      await pumpLoggedIn(tester, server, store, 'osama');
      await openMemberMenu(tester, 2);
      await tapText(tester, 'Change role');
      await tapKey(tester, 'member-role');
      await tapText(tester, 'Moderator');
      await tapKey(tester, 'member-role-save');

      expect(server.user('friend').role, Role.moderator);
      expect(find.textContaining('Moderator'), findsWidgets);
    });

    testWidgets('owner bans with a reason; the login then says why', (
      tester,
    ) async {
      final friendToken = server.sessionFor('friend');
      await pumpLoggedIn(tester, server, store, 'osama');
      await openMemberMenu(tester, 2);
      await tapText(tester, 'Ban');
      await type(tester, 'ban-reason', 'spam');
      await tapKey(tester, 'confirm-ban');

      final friend = server.user('friend');
      expect(friend.banned, isTrue);
      expect(friend.banReason, 'spam');
      expect(server.tokens.containsKey(friendToken), isFalse); // signed out
      expect(find.textContaining('banned'), findsOneWidget); // in the list

      // Unban from the same menu.
      await tapKey(tester, 'member-menu-2');
      await tapText(tester, 'Unban');
      expect(friend.banned, isFalse);
    });

    testWidgets('a banned user sees the reason when logging in', (
      tester,
    ) async {
      server.user('friend')
        ..banned = true
        ..banReason = 'spam';
      store.server = serverUrl;
      await pumpApp(tester, server, store);

      await type(tester, 'username', 'friend');
      await type(tester, 'password', 'friend-pass-1');
      await tapKey(tester, 'submit');
      expect(find.text('This account is banned: spam'), findsOneWidget);
    });

    testWidgets('moderator can kick a member but not an admin', (
      tester,
    ) async {
      server.users.addAll([
        FakeUser(3, 'mod', 'Mod', 'mod-pass-1', role: Role.moderator),
        FakeUser(4, 'adm', 'Adm', 'adm-pass-1', role: Role.admin),
      ]);
      final friendToken = server.sessionFor('friend');
      await pumpLoggedIn(tester, server, store, 'mod');
      await accountMenu(tester, 'Members');
      expect(find.byKey(const Key('member-menu-4')), findsNothing);

      await tapKey(tester, 'member-menu-2');
      expect(find.text('Change role'), findsNothing); // no manage_roles
      expect(find.text('Ban'), findsNothing); // no ban_members
      await tapText(tester, 'Kick (sign out everywhere)');
      await tapKey(tester, 'confirm-action');
      expect(server.tokens.containsKey(friendToken), isFalse);
    });

    testWidgets('my own promotion shows new tools right away', (tester) async {
      await pumpLoggedIn(tester, server, store, 'friend');
      expect(find.byKey(const Key('new-room')), findsNothing);

      final me = server.user('friend')..role = Role.admin;
      server.pushAll('member.updated', {
        'id': me.id,
        'username': me.username,
        'display_name': me.displayName,
        'role': 'admin',
      });
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('new-room')), findsOneWidget);
      expect(find.text('admin'), findsOneWidget); // account bar
    });
  });
}
