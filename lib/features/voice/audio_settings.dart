import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's voice audio choices. Saved on this computer (they are not secrets).
class AudioSettings {
  const AudioSettings({
    this.inputId,
    this.outputId,
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGain = true,
  });

  /// Chosen microphone / speaker; null = Windows' default device.
  final String? inputId;
  final String? outputId;

  /// WebRTC's audio processing. Echo cancellation stops the others from hearing
  /// themselves through your speakers; turn it off only with headphones.
  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGain;

  AudioSettings copyWith({
    String? Function()? inputId,
    String? Function()? outputId,
    bool? echoCancellation,
    bool? noiseSuppression,
    bool? autoGain,
  }) => AudioSettings(
    inputId: inputId != null ? inputId() : this.inputId,
    outputId: outputId != null ? outputId() : this.outputId,
    echoCancellation: echoCancellation ?? this.echoCancellation,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    autoGain: autoGain ?? this.autoGain,
  );
}

/// Where the settings are kept. Tests use a memory version.
abstract interface class AudioSettingsStore {
  Future<AudioSettings> load();
  Future<void> save(AudioSettings settings);
}

class PrefsAudioSettingsStore implements AudioSettingsStore {
  static const _prefix = 'voice.';

  @override
  Future<AudioSettings> load() async {
    final SharedPreferences p;
    try {
      p = await SharedPreferences.getInstance();
    } on Object {
      return const AudioSettings(); // unreadable settings must not block voice
    }
    return AudioSettings(
      inputId: p.getString('${_prefix}input'),
      outputId: p.getString('${_prefix}output'),
      echoCancellation: p.getBool('${_prefix}echo') ?? true,
      noiseSuppression: p.getBool('${_prefix}noise') ?? true,
      autoGain: p.getBool('${_prefix}gain') ?? true,
    );
  }

  @override
  Future<void> save(AudioSettings s) async {
    final p = await SharedPreferences.getInstance();
    Future<void> setOrRemove(String key, String? value) => value == null
        ? p.remove('$_prefix$key')
        : p.setString('$_prefix$key', value);
    await setOrRemove('input', s.inputId);
    await setOrRemove('output', s.outputId);
    await p.setBool('${_prefix}echo', s.echoCancellation);
    await p.setBool('${_prefix}noise', s.noiseSuppression);
    await p.setBool('${_prefix}gain', s.autoGain);
  }
}

final audioSettingsStoreProvider = Provider<AudioSettingsStore>(
  (ref) => PrefsAudioSettingsStore(),
);

/// The current settings: `ref.watch(audioSettingsProvider)`.
final audioSettingsProvider =
    AsyncNotifierProvider<AudioSettingsController, AudioSettings>(
      AudioSettingsController.new,
    );

class AudioSettingsController extends AsyncNotifier<AudioSettings> {
  @override
  Future<AudioSettings> build() => ref.read(audioSettingsStoreProvider).load();

  Future<void> save(AudioSettings settings) async {
    state = AsyncData(settings);
    await ref.read(audioSettingsStoreProvider).save(settings);
  }
}
