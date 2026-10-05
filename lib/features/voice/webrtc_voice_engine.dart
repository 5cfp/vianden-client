import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'voice_engine.dart';

/// The real voice engine, on flutter_webrtc (Google's WebRTC library underneath).
class WebrtcVoiceEngine implements VoiceEngine {
  @override
  Future<VoicePeer> connect({required bool withMic}) async {
    // No STUN/TURN servers: the server tells us its reachable addresses itself.
    final pc = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    MediaStream? mic;
    if (withMic) {
      // Echo cancellation and noise suppression: built into WebRTC, on by default here.
      mic = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      // Added BEFORE the first offer arrives: WebRTC then uses it for the server's
      // "send me your microphone" slot (see docs/API.md, Voice signaling).
      for (final track in mic.getAudioTracks()) {
        await pc.addTrack(track, mic);
      }
    }
    return _WebrtcPeer(pc, mic);
  }
}

class _WebrtcPeer implements VoicePeer {
  _WebrtcPeer(this._pc, this._mic) {
    _pc.onIceCandidate = (c) {
      if (c.candidate != null) _candidates.add(Map.of(c.toMap() as Map).cast());
    };
    _pc.onConnectionState = (s) => _link.add(switch (s) {
      RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
        VoiceLink.connected,
      RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
      RTCPeerConnectionState.RTCPeerConnectionStateClosed => VoiceLink.failed,
      _ => VoiceLink.connecting,
    });
    // Remote audio plays by itself; we only keep the tracks to be able to deafen.
    _pc.onTrack = (e) {
      if (e.track.kind == 'audio') {
        e.track.enabled = _outputEnabled;
        _remote.add(e.track);
      }
    };
    if (_mic != null) {
      _levelTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _readLevel(),
      );
    }
  }

  final RTCPeerConnection _pc;
  final MediaStream? _mic;
  final _remote = <MediaStreamTrack>[];
  final _candidates = StreamController<Map<String, dynamic>>.broadcast();
  final _link = StreamController<VoiceLink>.broadcast();
  final _level = StreamController<double>.broadcast();
  Timer? _levelTimer;
  bool _outputEnabled = true;

  @override
  Future<String> answer(String offerSdp) async {
    await _pc.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final answer = await _pc.createAnswer({});
    await _pc.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> c) => _pc.addCandidate(
    RTCIceCandidate(
      c['candidate'] as String?,
      c['sdpMid'] as String?,
      c['sdpMLineIndex'] as int?,
    ),
  );

  @override
  Stream<Map<String, dynamic>> get candidates => _candidates.stream;

  @override
  Stream<VoiceLink> get link => _link.stream;

  @override
  Stream<double> get micLevel => _level.stream;

  /// The microphone level from WebRTC's statistics ("media-source", audioLevel 0..1).
  Future<void> _readLevel() async {
    try {
      for (final report in await _pc.getStats()) {
        if (report.type != 'media-source') continue;
        if (report.values['audioLevel'] case final num level) {
          if (!_level.isClosed) _level.add(level.toDouble());
          return;
        }
      }
    } on Object {
      // Statistics are best effort: no level means no "speaking" indicator, nothing else.
    }
  }

  @override
  void setMicEnabled(bool enabled) {
    for (final t in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  @override
  void setOutputEnabled(bool enabled) {
    _outputEnabled = enabled;
    for (final t in _remote) {
      t.enabled = enabled;
    }
  }

  @override
  Future<void> close() async {
    _levelTimer?.cancel();
    for (final t in _mic?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop(); // releases the microphone (the OS "in use" indicator goes off)
    }
    await _mic?.dispose();
    await _pc.close();
    await _pc.dispose();
    await _candidates.close();
    await _link.close();
    await _level.close();
  }
}
