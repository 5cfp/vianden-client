import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/session_controller.dart';
import '../chat/realtime_controller.dart';
import 'audio_settings.dart';
import 'system_audio.dart';
import 'voice_engine.dart';

enum VoicePhase { idle, connecting, connected }

/// Everything the UI shows about voice.
class VoiceState {
  const VoiceState({
    this.channelId,
    this.phase = VoicePhase.idle,
    this.canSpeak = false,
    this.micAvailable = true,
    this.muted = false,
    this.deafened = false,
    this.rooms = const {},
    this.speaking = const {},
    this.notice,
  });

  /// The voice channel we are in (or joining); null = not in voice.
  final int? channelId;
  final VoicePhase phase;

  /// Our role may speak here, and we have a microphone.
  final bool canSpeak;
  final bool micAvailable;
  final bool muted;
  final bool deafened;

  /// Who is in each voice channel we can see (from the server).
  final Map<int, List<VoiceParticipant>> rooms;

  /// User ids that are speaking right now.
  final Set<int> speaking;

  /// Something to tell the user once (e.g. "Disconnected by a moderator").
  final String? notice;

  VoiceState copyWith({
    int? Function()? channelId,
    VoicePhase? phase,
    bool? canSpeak,
    bool? micAvailable,
    bool? muted,
    bool? deafened,
    Map<int, List<VoiceParticipant>>? rooms,
    Set<int>? speaking,
    String? Function()? notice,
  }) => VoiceState(
    channelId: channelId != null ? channelId() : this.channelId,
    phase: phase ?? this.phase,
    canSpeak: canSpeak ?? this.canSpeak,
    micAvailable: micAvailable ?? this.micAvailable,
    muted: muted ?? this.muted,
    deafened: deafened ?? this.deafened,
    rooms: rooms ?? this.rooms,
    speaking: speaking ?? this.speaking,
    notice: notice != null ? notice() : this.notice,
  );
}

/// Voice: joining and leaving, the WebRTC signaling with the server (over the
/// WebSocket), mute and deafen, and the "speaking" indicator.
final voiceProvider = NotifierProvider.autoDispose<VoiceController, VoiceState>(
  VoiceController.new,
);

class VoiceController extends Notifier<VoiceState> {
  /// Microphone level above which we count as speaking (0..1).
  static const speakingThreshold = 0.04;

  /// How long the level must stay low before "speaking" turns off (no flicker).
  static const speakingHold = Duration(milliseconds: 400);

  VoicePeer? _peer;
  final _subs = <StreamSubscription<Object?>>[];

  /// Signaling steps run one after another: an offer must wait until the connection
  /// (and the microphone) is ready.
  Future<void> _queue = Future.value();

  bool _speaking = false;
  DateTime _lastLoud = DateTime(0);

  @override
  VoiceState build() {
    ref.onDispose(_closePeer);
    return const VoiceState();
  }

  RealtimeController get _rt => ref.read(realtimeProvider.notifier);

  int? get _myId => switch (ref.read(sessionProvider).value) {
    LoggedIn(:final user) => user.id,
    _ => null,
  };

  void _enqueue(Future<void> Function() step) {
    _queue = _queue.then((_) => step()).catchError((Object _) {});
  }

  // ---- what the user does ----

  void join(int channelId) {
    if (state.channelId == channelId && state.phase != VoicePhase.idle) return;
    if (state.channelId != null) _closePeerSoon(); // switching channels
    state = state.copyWith(
      channelId: () => channelId,
      phase: VoicePhase.connecting,
      notice: () => null,
    );
    _rt.send('voice.join', {'channel_id': channelId});
  }

  void leave() {
    if (state.channelId == null) return;
    _rt.send('voice.leave', {});
    _reset();
  }

  void toggleMute() {
    if (state.deafened) {
      // Like most voice apps: unmuting while deafened also undeafens.
      _setSelf(muted: false, deafened: false);
    } else {
      _setSelf(muted: !state.muted, deafened: false);
    }
  }

  void toggleDeafen() {
    // Deafened people are muted too (you cannot hear the answer to what you say).
    final deaf = !state.deafened;
    _setSelf(muted: deaf ? true : false, deafened: deaf);
  }

  void clearNotice() => state = state.copyWith(notice: () => null);

  /// New audio settings: if we are in voice, rejoin so they take effect (WebRTC cannot
  /// switch devices inside a running call).
  void applyAudioSettings() {
    final id = state.channelId;
    if (id == null) return;
    _closePeerSoon();
    state = state.copyWith(phase: VoicePhase.connecting);
    _rt.send('voice.join', {'channel_id': id});
  }

  void _setSelf({required bool muted, required bool deafened}) {
    state = state.copyWith(muted: muted, deafened: deafened);
    _peer?.setMicEnabled(!muted);
    _peer?.setOutputEnabled(!deafened);
    if (muted) _setSpeaking(false);
    if (state.channelId != null) {
      _rt.send('voice.self', {'muted': muted, 'deafened': deafened});
    }
  }

  // ---- events from the server (the realtime controller passes all voice.* here) ----

  void handleEvent(String type, Object? data) {
    if (data is! Map) return;
    switch (type) {
      case 'voice.joined':
        final canSpeak = data['can_speak'] == true;
        final hadMic = state.canSpeak && state.micAvailable;
        state = state.copyWith(canSpeak: canSpeak);
        if (_peer == null) {
          _enqueue(() => _connect(withMic: canSpeak));
        } else if (canSpeak && !hadMic && state.micAvailable) {
          // We may speak now but have no microphone in this connection: rejoin.
          final id = state.channelId;
          _closePeerSoon();
          if (id != null) _rt.send('voice.join', {'channel_id': id});
        }
      case 'voice.offer':
        final sdp = data['sdp'];
        if (sdp is! String) return;
        _enqueue(() async {
          final peer = _peer;
          if (peer == null) return;
          final answer = await peer.answer(sdp);
          if (identical(peer, _peer)) _rt.send('voice.answer', {'sdp': answer});
        });
      case 'voice.candidate':
        final c = data['candidate'];
        if (c is! Map) return;
        _enqueue(() async => _peer?.addCandidate(Map.of(c).cast()));
      case 'voice.left':
        _reset(notice: _reasonText(data['reason']));
      case 'voice.error':
        _reset(
          notice: data['message'] is String
              ? data['message'] as String
              : 'Voice failed.',
        );
      case 'voice.state':
        try {
          final st = VoiceChannelState.fromJson(data);
          state = state.copyWith(
            rooms: {...state.rooms, st.channelId: st.participants},
          );
        } on FormatException {
          return;
        }
      case 'voice.speaking':
        if (data case {'user_id': int user, 'speaking': bool on}) {
          final next = {...state.speaking};
          on ? next.add(user) : next.remove(user);
          state = state.copyWith(speaking: next);
        }
    }
  }

  /// The WebSocket (re)connected. The server ended any voice session of the old
  /// connection, so rejoin, and load who is in voice now.
  Future<void> onConnected() async {
    final id = state.channelId;
    if (id != null) {
      _closePeerSoon();
      state = state.copyWith(phase: VoicePhase.connecting);
      _rt.send('voice.join', {'channel_id': id});
    }
    try {
      final list = await ref
          .read(sessionProvider.notifier)
          .authorizedApi()
          .listVoice();
      if (!ref.mounted) return;
      state = state.copyWith(
        rooms: {for (final c in list) c.channelId: c.participants},
      );
    } on ApiException {
      return;
    } on NetworkException {
      return;
    }
  }

  // ---- the WebRTC connection ----

  Future<void> _connect({required bool withMic}) async {
    final engine = ref.read(voiceEngineProvider);
    final settings = await ref.read(audioSettingsProvider.future);
    // Before any audio stream opens: Windows must not turn other apps down.
    await ref.read(systemAudioProvider)();
    VoicePeer peer;
    var micOk = true;
    try {
      peer = await engine.connect(withMic: withMic, settings: settings);
    } on Object {
      if (!withMic) rethrow;
      // No microphone, or no permission (Windows: Settings > Privacy > Microphone).
      micOk = false;
      peer = await engine.connect(withMic: false, settings: settings);
    }
    if (!ref.mounted || state.channelId == null) {
      await peer.close();
      return;
    }
    _peer = peer;
    _subs
      ..add(
        peer.candidates.listen(
          (c) => _rt.send('voice.candidate', {'candidate': c}),
        ),
      )
      ..add(
        peer.link.listen((l) {
          if (l == VoiceLink.connected) {
            // Again now that the streams exist (the default device may have changed).
            ref.read(systemAudioProvider)();
            state = state.copyWith(phase: VoicePhase.connected);
          } else if (l == VoiceLink.failed && state.phase != VoicePhase.idle) {
            leave();
            state = state.copyWith(notice: () => 'Voice connection lost.');
          }
        }),
      )
      ..add(peer.micLevel.listen(_onLevel));
    state = state.copyWith(
      micAvailable: micOk,
      notice: micOk
          ? null
          : () => 'No microphone available: you can only listen.',
    );
    peer.setMicEnabled(!state.muted);
    peer.setOutputEnabled(!state.deafened);
    if (state.muted || state.deafened) {
      _rt.send('voice.self', {
        'muted': state.muted,
        'deafened': state.deafened,
      });
    }
  }

  void _onLevel(double level) {
    if (state.muted || !state.canSpeak) return;
    final now = clock.now();
    if (level >= speakingThreshold) {
      _lastLoud = now;
      _setSpeaking(true);
    } else if (now.difference(_lastLoud) > speakingHold) {
      _setSpeaking(false);
    }
  }

  void _setSpeaking(bool on) {
    if (_speaking == on) return;
    _speaking = on;
    _rt.send('voice.speaking', {'speaking': on});
  }

  void _reset({String? notice}) {
    _closePeerSoon();
    final me = _myId;
    state = state.copyWith(
      channelId: () => null,
      phase: VoicePhase.idle,
      speaking: {...state.speaking}..remove(me),
      notice: () => notice,
    );
  }

  void _closePeerSoon() {
    final peer = _peer;
    _peer = null;
    _speaking = false;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    if (peer != null) _enqueue(peer.close);
  }

  void _closePeer() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _peer?.close();
    _peer = null;
  }

  static String? _reasonText(Object? reason) => switch (reason) {
    'left' || null => null,
    'disconnected' => 'A moderator disconnected you from voice.',
    'joined_elsewhere' => 'You joined voice somewhere else.',
    'connection_lost' => 'Voice connection lost.',
    'no_access' => 'You can no longer join this voice channel.',
    'channel_deleted' => 'The voice channel was deleted.',
    'server_stopping' => 'The server is restarting.',
    _ => 'You left voice.',
  };
}
