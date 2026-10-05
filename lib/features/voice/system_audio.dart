import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Talks to the native Windows code in `windows/runner/audio_ducking.cpp`.
const _channel = MethodChannel('vianden/audio');

/// Windows treats voice like a phone call and turns all other sounds down (by 80% by
/// default). This tells Windows not to do that for our app, so music, games and videos
/// keep their volume while you are in a voice channel. Safe to call any time; does
/// nothing on other platforms or if it fails.
Future<void> keepOtherSoundsUnchanged() async {
  if (!Platform.isWindows) return;
  try {
    await _channel.invokeMethod<int>('disableDucking');
  } on Object {
    // Not running in the real app (tests), or Windows refused: voice works anyway.
  }
}

/// What voice calls to keep other sounds at their volume. Tests replace it.
final systemAudioProvider = Provider<Future<void> Function()>(
  (ref) => keepOtherSoundsUnchanged,
);
