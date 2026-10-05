import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/features/voice/voice_engine.dart';

import 'helpers.dart';

/// Voice audio settings: choosing the microphone and speaker, and audio processing.
void main() {
  late FakeServer server;
  late MemorySessionStore store;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
    server.channels.add(FakeChannel(5, 'Lounge')..type = 'voice');
  });

  test('device choice: the chosen one, else Windows default, else none', () {
    const devs = AudioDevices(
      inputs: [AudioDevice('a', 'A'), AudioDevice('b', 'B')],
      defaultInput: 'b',
    );
    expect(devs.input('a'), 'a');
    expect(devs.input(null), 'b'); // Windows default, not simply the first one
    expect(devs.input('unplugged'), 'b');
    expect(
      const AudioDevices(inputs: [AudioDevice('a', 'A')]).input(null),
      isNull,
    );
  });

  testWidgets('without settings, voice uses Windows defaults', (tester) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await tapKey(tester, 'voice-5');
    final s = server.voiceEngine.connectedWith.single;
    expect(
      s.inputId,
      isNull,
    ); // = default; the engine resolves it to Windows' choice
    expect(s.echoCancellation, isTrue);
    expect(s.noiseSuppression, isTrue);
  });

  testWidgets('choose devices and processing in the dialog', (tester) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await accountMenu(tester, 'Voice & audio');
    expect(find.text('Windows default (USB Microphone)'), findsOneWidget);

    await tapKey(tester, 'audio-output');
    await tapText(tester, 'Headphones');
    await tapKey(tester, 'audio-noise'); // turn noise suppression off
    await tapKey(tester, 'audio-save');

    final saved = server.audioSettings.saved;
    expect(saved.outputId, 'spk-bt');
    expect(saved.inputId, isNull);
    expect(saved.noiseSuppression, isFalse);

    // The next voice connection uses them.
    await tapKey(tester, 'voice-5');
    expect(server.voiceEngine.connectedWith.last.outputId, 'spk-bt');
    expect(server.voiceEngine.connectedWith.last.noiseSuppression, isFalse);
  });

  testWidgets('changing devices during a call reconnects with them', (
    tester,
  ) async {
    await pumpLoggedIn(tester, server, store, 'friend');
    await tapKey(tester, 'voice-5');
    final first = server.voiceEngine.last!;

    await tapKey(tester, 'voice-settings');
    await tapKey(tester, 'audio-input');
    await tapText(tester, 'Headset (hands-free)');
    await tapKey(tester, 'audio-save');

    expect(first.closed, isTrue);
    expect(server.voiceEngine.peers, hasLength(2));
    expect(server.voiceEngine.connectedWith.last.inputId, 'mic-bt');
    expect(
      server.voiceRooms[5]!.single.user.username,
      'friend',
    ); // still in voice
    expect(find.byKey(const Key('voice-panel')), findsOneWidget);
  });
}
