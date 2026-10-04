import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/core/models.dart';

import 'attachments_test.dart' show FakeFileSelector;
import 'helpers.dart';

/// M6 step 4: display names and avatars.
void main() {
  late FakeServer server;
  late MemorySessionStore store;
  late FakeFileSelector picker;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
    picker = FakeFileSelector();
    FileSelectorPlatform.instance = picker;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }
  }

  test('only avatar paths on the server are accepted', () {
    User user(Object? avatar) => User.fromJson({
      'id': 1,
      'username': 'a',
      'display_name': 'A',
      'role': 'member',
      'avatar': avatar,
    });
    final ok = '/api/v1/avatars/${'a' * 64}';
    expect(user(ok).avatar, ok);
    expect(user('https://evil.example/track.png').avatar, isNull);
    expect(user('/api/v1/avatars/../../me').avatar, isNull);
    expect(user(null).avatar, isNull);
  });

  testWidgets('change your display name', (tester) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await accountMenu(tester, 'Profile');
    await type(tester, 'profile-name', '  Night Owl  ');
    await tapKey(tester, 'profile-save');

    expect(server.user('friend').displayName, 'Night Owl');
    expect(find.text('Night Owl'), findsOneWidget); // account bar
  });

  testWidgets('a bad name shows the server error and keeps the dialog', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await accountMenu(tester, 'Profile');
    await type(tester, 'profile-name', '   ');
    await tapKey(tester, 'profile-save');
    expect(find.textContaining('1-32 characters'), findsOneWidget);
    expect(find.byKey(const Key('profile-name')), findsOneWidget);
  });

  testWidgets('set and remove an avatar', (tester) async {
    picker.toOpen = [XFile.fromData(tinyPng, path: 'me.png')];
    await pumpLoggedIn(tester, server, store, 'friend');
    expect(find.byKey(const Key('avatar-image')), findsNothing);

    await accountMenu(tester, 'Profile');
    await tapKey(tester, 'change-avatar');
    await settle(tester);
    expect(server.user('friend').avatar, isNotNull);
    // Shown in the dialog and in the account bar.
    expect(find.byKey(const Key('avatar-image')), findsNWidgets(2));

    await tapKey(tester, 'remove-avatar');
    await settle(tester);
    expect(server.user('friend').avatar, isNull);
    expect(find.byKey(const Key('avatar-image')), findsNothing);
  });

  testWidgets('someone else renaming shows on their old messages', (
    tester,
  ) async {
    server.post(1, 'osama', 'hello from before');
    await pumpLoggedIn(tester, server, store, 'friend');
    expect(find.textContaining('Osama', findRichText: true), findsWidgets);

    final osama = server.user('osama')..displayName = 'The Boss';
    server.pushAll('member.updated', {
      'id': osama.id,
      'username': osama.username,
      'display_name': osama.displayName,
      'role': 'owner',
      'avatar': null,
    });
    await settle(tester);
    expect(find.textContaining('The Boss', findRichText: true), findsWidgets);
  });
}
