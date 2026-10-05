import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'webrtc_voice_engine.dart';

/// The WebRTC side of voice, kept behind a small interface: the app uses
/// [WebrtcVoiceEngine] (flutter_webrtc), tests use a fake. Everything else (signaling,
/// state, UI) is plain Dart and can be tested without a microphone.
abstract interface class VoiceEngine {
  /// Opens a connection to the server's SFU. With [withMic], the microphone is captured
  /// and sent (needs the user's permission); without it, the user only listens.
  Future<VoicePeer> connect({required bool withMic});
}

enum VoiceLink { connecting, connected, failed }

/// One WebRTC connection to the server. The server always makes the offers.
abstract interface class VoicePeer {
  /// Applies the server's offer and returns our answer (SDP text).
  Future<String> answer(String offerSdp);

  /// Adds one of the server's network candidates (`RTCIceCandidateInit` as JSON).
  Future<void> addCandidate(Map<String, dynamic> candidate);

  /// Our own network candidates, to send to the server.
  Stream<Map<String, dynamic>> get candidates;

  /// Connection progress.
  Stream<VoiceLink> get link;

  /// Microphone level, 0.0 (silence) to 1.0, a few times per second.
  Stream<double> get micLevel;

  /// Mute: stop sending our microphone (the track sends silence).
  void setMicEnabled(bool enabled);

  /// Deafen: stop playing everyone else.
  void setOutputEnabled(bool enabled);

  Future<void> close();
}

/// Which engine the app uses. Tests override this with a fake.
final voiceEngineProvider = Provider<VoiceEngine>((ref) => WebrtcVoiceEngine());
