import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/core/permissions.dart';
import 'package:vianden_client/features/voice/voice_engine.dart';

import 'helpers.dart';

/// M7: voice channels. WebRTC itself is faked (FakeVoiceEngine); the FakeServer plays
/// the server's side of the signaling like docs/API.md describes.
void main() {
  late FakeServer server;
  late MemorySessionStore store;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
    server.channels.add(FakeChannel(5, 'Lounge')..type = 'voice');
  });

  List<String> voiceSent() => [for (final (t, _) in server.voiceLog) t];

  Future<void> joinLounge(WidgetTester tester) async {
    await tapKey(tester, 'voice-5');
    await tester.pumpAndSettle();
  }

  testWidgets('voice rooms are listed apart and never open as a chat', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    expect(find.text('Voice'), findsOneWidget);
    expect(find.byKey(const Key('voice-5')), findsOneWidget);
    expect(
      find.byKey(const Key('room-2')),
      findsNothing,
    ); // not a text room tile
    expect(find.byKey(const Key('voice-panel')), findsNothing);
  });

  testWidgets('joining: signaling, panel, participant list', (tester) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await joinLounge(tester);

    final peer = server.voiceEngine.last!;
    expect(peer.withMic, isTrue); // members may speak in an open room
    // Windows was asked not to turn other sounds down (before any audio stream).
    expect(server.duckingOptOuts, greaterThanOrEqualTo(1));
    // Our answer to the server's offer, and the server's candidate, were handled.
    expect(peer.offers, ['offer-1']);
    expect(server.voiceLog.where((e) => e.$1 == 'voice.answer').single.$2, {
      'sdp': 'answer-to-offer-1',
    });
    expect(peer.remoteCandidates.single['candidate'], 'server-candidate');

    // Our own candidates go to the server.
    peer.candidateCtl.add({'candidate': 'my-candidate', 'sdpMid': '0'});
    await tester.pumpAndSettle();
    expect(voiceSent(), contains('voice.candidate'));

    expect(find.text('Connecting…'), findsOneWidget);
    peer.linkCtl.add(VoiceLink.connected);
    await tester.pumpAndSettle();
    expect(find.text('Voice connected'), findsOneWidget);
    // We show up under the channel (from the server's voice.state).
    expect(find.byKey(const Key('voice-user-2')), findsOneWidget);
  });

  testWidgets('mute, deafen and leave', (tester) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await joinLounge(tester);
    final peer = server.voiceEngine.last!;

    await tapKey(tester, 'voice-mute');
    expect(peer.micEnabled, isFalse);
    expect(server.voiceRooms[5]!.single.muted, isTrue);

    await tapKey(tester, 'voice-deafen');
    expect(peer.outputEnabled, isFalse);
    expect(server.voiceRooms[5]!.single.deafened, isTrue);

    await tapKey(tester, 'voice-deafen'); // undeafen also unmutes
    expect(peer.outputEnabled, isTrue);
    expect(peer.micEnabled, isTrue);

    await tapKey(tester, 'voice-leave');
    expect(voiceSent().last, 'voice.leave');
    expect(peer.closed, isTrue);
    expect(find.byKey(const Key('voice-panel')), findsNothing);
    expect(server.voiceRooms[5], isEmpty);
  });

  testWidgets('listen-only rooms do not use the microphone', (tester) async {
    server.channels.last.sendRole = Role.moderator;
    await pumpLoggedIn(tester, server, store, 'friend');
    await joinLounge(tester);

    expect(server.voiceEngine.last!.withMic, isFalse);
    expect(find.textContaining('listening only'), findsOneWidget);
    expect(find.byKey(const Key('voice-mute')), findsNothing);
  });

  testWidgets('no microphone: falls back to listening, and says so', (
    tester,
  ) async {
    server.voiceEngine.micFails = true;
    await pumpLoggedIn(tester, server, store, 'friend');
    await joinLounge(tester);

    expect(server.voiceEngine.last!.withMic, isFalse);
    expect(find.textContaining('No microphone'), findsWidgets);
  });

  testWidgets('speaking: our level is reported, others light up', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await joinLounge(tester);
    final peer = server.voiceEngine.last!;

    peer.levelCtl.add(0.5);
    await tester.pumpAndSettle();
    expect(server.voiceLog.last.$1, 'voice.speaking');
    expect(server.voiceLog.last.$2['speaking'], isTrue);
    // The fake server echoes it to the room, so our own avatar gets the ring.
    expect(find.byKey(const Key('speaking-2')), findsOneWidget);

    // Muted people never report speaking.
    await tapKey(tester, 'voice-mute');
    peer.levelCtl.add(0.9);
    await tester.pumpAndSettle();
    expect(
      server.voiceLog.where((e) => e.$2['speaking'] == true),
      hasLength(1),
    );
  });

  testWidgets('moderators can server-mute and disconnect people below them', (
    tester,
  ) async {
    final friend = server.user('friend');
    server.voiceRooms[5] = [FakeVoiceMember(friend, null)];
    await pumpLoggedIn(tester, server, store, 'osama');
    expect(
      find.byKey(const Key('voice-user-2')),
      findsOneWidget,
    ); // from GET /voice

    await tapKey(tester, 'voice-menu-2');
    await tapText(tester, 'Mute for everyone');
    expect(server.voiceRooms[5]!.single.serverMuted, isTrue);
    expect(find.byKey(const Key('server-muted-2')), findsOneWidget);

    await tapKey(tester, 'voice-menu-2');
    await tapText(tester, 'Disconnect');
    expect(server.voiceRooms[5], isEmpty);
    expect(find.byKey(const Key('voice-user-2')), findsNothing);
  });

  testWidgets('members get no moderation menu', (tester) async {
    server.voiceRooms[5] = [FakeVoiceMember(server.user('osama'), null)];
    await pumpLoggedIn(tester, server, store, 'friend');
    expect(find.byKey(const Key('voice-user-1')), findsOneWidget);
    expect(find.byKey(const Key('voice-menu-1')), findsNothing);
  });

  testWidgets('being disconnected by a moderator is explained', (tester) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await joinLounge(tester);
    final me = server.voiceRooms[5]!.single;
    me.conn!.push('voice.left', {'channel_id': 5, 'reason': 'disconnected'});
    await tester.pumpAndSettle();

    expect(
      find.text('A moderator disconnected you from voice.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('voice-panel')), findsNothing);
    expect(server.voiceEngine.last!.closed, isTrue);
  });

  testWidgets('after a reconnect the app joins its voice channel again', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await joinLounge(tester);
    expect(voiceSent().where((t) => t == 'voice.join'), hasLength(1));

    server.dropAll(); // network drop: the server forgets the voice session
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(voiceSent().where((t) => t == 'voice.join'), hasLength(2));
    expect(server.voiceRooms[5]!.single.user.username, 'friend');
    expect(
      server.voiceEngine.peers.first.closed,
      isTrue,
    ); // old connection closed
  });

  testWidgets('create a voice room', (tester) async {
    await pumpLoggedIn(tester, server, store, 'osama');
    await tapKey(tester, 'new-room');
    await tapText(tester, 'Voice');
    expect(find.text('Who can speak'), findsOneWidget);
    await type(tester, 'room-name', 'Gaming');
    await tapKey(tester, 'room-save');

    final created = server.channels.last;
    expect((created.name, created.type), ('Gaming', 'voice'));
    expect(find.byKey(Key('voice-${created.id}')), findsOneWidget);
  });

  testWidgets('a server without voice shows it and does not join', (
    tester,
  ) async {
    server.voiceAvailable = false;
    await pumpLoggedIn(tester, server, store, 'friend');
    expect(find.text('Voice (not available on this server)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-5')));
    await tester.pumpAndSettle();
    expect(voiceSent(), isEmpty);
  });
}
