import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio_settings.dart';
import 'webrtc_voice_engine.dart';

/// The WebRTC side of voice, kept behind a small interface: the app uses
/// [WebrtcVoiceEngine] (flutter_webrtc), tests use a fake. Everything else (signaling,
/// state, UI) is plain Dart and can be tested without a microphone.
abstract interface class VoiceEngine {
  /// Opens a connection to the server's SFU. With [withMic], the microphone is captured
  /// and sent (needs the user's permission); without it, the user only listens.
  /// [settings] choose the devices and audio processing.
  Future<VoicePeer> connect({
    required bool withMic,
    AudioSettings settings = const AudioSettings(),
  });

  /// The microphones and speakers on this computer, and which are Windows' defaults.
  Future<AudioDevices> devices();
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

/// One microphone or speaker.
class AudioDevice {
  const AudioDevice(this.id, this.label);
  final String id;
  final String label;
}

class AudioDevices {
  const AudioDevices({
    this.inputs = const [],
    this.outputs = const [],
    this.defaultInput,
    this.defaultOutput,
  });

  final List<AudioDevice> inputs;
  final List<AudioDevice> outputs;

  /// Windows' default devices (ids from [inputs] / [outputs]); null if unknown.
  final String? defaultInput;
  final String? defaultOutput;

  /// The device to use: the chosen one if it is still connected, else the default.
  /// null = none known (WebRTC then picks one itself).
  String? input(String? chosen) => _pick(inputs, chosen, defaultInput);
  String? output(String? chosen) => _pick(outputs, chosen, defaultOutput);

  static String? _pick(List<AudioDevice> list, String? chosen, String? def) {
    bool has(String? id) => id != null && list.any((d) => d.id == id);
    if (has(chosen)) return chosen;
    if (has(def)) return def;
    return null;
  }
}
