import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import 'audio_settings.dart';
import 'voice_controller.dart';
import 'voice_engine.dart';

/// Microphone, speaker and audio processing for voice.
Future<void> showAudioSettingsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _AudioSettingsDialog(),
);

class _AudioSettingsDialog extends ConsumerStatefulWidget {
  const _AudioSettingsDialog();

  @override
  ConsumerState<_AudioSettingsDialog> createState() =>
      _AudioSettingsDialogState();
}

class _AudioSettingsDialogState extends ConsumerState<_AudioSettingsDialog> {
  late final Future<AudioDevices> _devices = ref
      .read(voiceEngineProvider)
      .devices();
  AudioSettings? _edit; // the user's unsaved changes

  /// Dropdown value for "Windows default".
  static const _defaultValue = '';

  Future<void> _save(AudioSettings s) async {
    await ref.read(audioSettingsProvider.notifier).save(s);
    // In a call: rejoin so the new devices / processing take effect.
    ref.read(voiceProvider.notifier).applyAudioSettings();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(audioSettingsProvider).value;
    final s = _edit ?? saved ?? const AudioSettings();
    final muted = Theme.of(context).extension<ChatColors>()!.muted;

    return AlertDialog(
      title: const Text('Voice & audio'),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<AudioDevices>(
          future: _devices,
          builder: (context, snap) {
            if (snap.hasError) {
              return Text('Could not list audio devices: ${snap.error}');
            }
            final devs = snap.data;
            if (devs == null) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _deviceDropdown(
                  key: const Key('audio-input'),
                  label: 'Microphone',
                  devices: devs.inputs,
                  defaultId: devs.defaultInput,
                  value: s.inputId,
                  onChanged: (id) =>
                      setState(() => _edit = s.copyWith(inputId: () => id)),
                ),
                const SizedBox(height: AppSpacing.medium),
                _deviceDropdown(
                  key: const Key('audio-output'),
                  label: 'Speaker / headphones',
                  devices: devs.outputs,
                  defaultId: devs.defaultOutput,
                  value: s.outputId,
                  onChanged: (id) =>
                      setState(() => _edit = s.copyWith(outputId: () => id)),
                ),
                const SizedBox(height: AppSpacing.small),
                Text(
                  'Tip: a Bluetooth headset\'s own microphone makes Windows switch the '
                  'headset to "hands-free" mode, which sounds like an old phone. For '
                  'good sound, use another microphone with Bluetooth headphones.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: muted),
                ),
                const SizedBox(height: AppSpacing.small),
                SwitchListTile(
                  key: const Key('audio-echo'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Echo cancellation'),
                  subtitle: const Text(
                    'Stops others from hearing themselves through your speakers',
                  ),
                  value: s.echoCancellation,
                  onChanged: (v) =>
                      setState(() => _edit = s.copyWith(echoCancellation: v)),
                ),
                SwitchListTile(
                  key: const Key('audio-noise'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Noise suppression'),
                  subtitle: const Text(
                    'Removes fans, typing and background hum',
                  ),
                  value: s.noiseSuppression,
                  onChanged: (v) =>
                      setState(() => _edit = s.copyWith(noiseSuppression: v)),
                ),
                SwitchListTile(
                  key: const Key('audio-gain'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Automatic volume'),
                  subtitle: const Text('Evens out quiet and loud speaking'),
                  value: s.autoGain,
                  onChanged: (v) =>
                      setState(() => _edit = s.copyWith(autoGain: v)),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('audio-save'),
          onPressed: _edit == null ? null : () => _save(_edit!),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _deviceDropdown({
    required Key key,
    required String label,
    required List<AudioDevice> devices,
    required String? defaultId,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    final defaultName = devices
        .where((d) => d.id == defaultId)
        .firstOrNull
        ?.label;
    // A saved device that is unplugged now: show "Windows default" (that is used).
    final current = devices.any((d) => d.id == value) ? value! : _defaultValue;
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: current,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(
          value: _defaultValue,
          child: Text(
            defaultName == null
                ? 'Windows default'
                : 'Windows default ($defaultName)',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final d in devices)
          DropdownMenuItem(
            value: d.id,
            child: Text(d.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (id) => onChanged(id == _defaultValue ? null : id),
    );
  }
}
