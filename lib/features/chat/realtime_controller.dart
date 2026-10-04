import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/realtime_connection.dart';
import '../../core/session_controller.dart';
import 'chat_providers.dart';

/// How the app opens live connections. Tests replace it with a fake.
final realtimeConnectorProvider = Provider<RealtimeConnector>(
  (ref) => WebSocketConnection.new,
);

/// The live connection's state: status, who is online, who is typing.
/// `autoDispose`: the connection closes when the chat screen closes (e.g. logout).
final realtimeProvider =
    NotifierProvider.autoDispose<RealtimeController, RealtimeState>(
      RealtimeController.new,
    );

enum ConnectionStatus { connecting, connected, reconnecting }

class RealtimeState {
  const RealtimeState({
    this.status = ConnectionStatus.connecting,
    this.online = const {},
    this.typing = const {},
  });

  final ConnectionStatus status;

  /// Users with at least one open connection, by id.
  final Map<int, Author> online;

  /// channel id -> (user id -> who is typing and until when).
  final Map<int, Map<int, Typist>> typing;

  /// Names of people typing in a channel right now.
  List<String> typingIn(int channelId) => [
    for (final t in (typing[channelId] ?? const <int, Typist>{}).values) t.name,
  ];

  RealtimeState copyWith({
    ConnectionStatus? status,
    Map<int, Author>? online,
    Map<int, Map<int, Typist>>? typing,
  }) => RealtimeState(
    status: status ?? this.status,
    online: online ?? this.online,
    typing: typing ?? this.typing,
  );
}

class Typist {
  const Typist(this.name, this.until);
  final String name;
  final DateTime until;
}

/// Keeps one live connection open while logged in, reconnects when it drops, and
/// feeds incoming events into the room and message state.
// Time comes from `clock.now()` instead of `DateTime.now()`: same result in the app,
// but tests can fast-forward it (the typing throttle and indicator depend on time).
class RealtimeController extends Notifier<RealtimeState> {
  static const typingShownFor = Duration(seconds: 5);
  static const typingSendEvery = Duration(seconds: 3);

  RealtimeConnection? _conn;
  bool _disposed = false;
  Timer? _typingTimer;
  Timer? _retryTimer;
  Completer<void>? _retryWait;
  final _lastTypingSent = <int, DateTime>{};
  final _random = Random();

  @override
  RealtimeState build() {
    ref.onDispose(() {
      _disposed = true;
      _typingTimer?.cancel();
      _retryTimer?.cancel();
      if (_retryWait?.isCompleted == false) _retryWait!.complete();
      _conn?.close();
    });
    Future.microtask(_run); // start connecting after build() returns
    return const RealtimeState();
  }

  /// Tells others that the user is typing in [channelId] (at most every 3 seconds).
  void sendTyping(int channelId) {
    final conn = _conn;
    if (conn == null || state.status != ConnectionStatus.connected) return;
    final now = clock.now();
    final last = _lastTypingSent[channelId];
    if (last != null && now.difference(last) < typingSendEvery) return;
    _lastTypingSent[channelId] = now;
    conn.send(
      jsonEncode({
        'type': 'typing',
        'data': {'channel_id': channelId},
      }),
    );
  }

  /// The connect / listen / reconnect loop. Runs until the controller is disposed.
  Future<void> _run() async {
    var failures = 0;
    var connectedBefore = false;

    while (!_disposed) {
      final session = ref.read(sessionProvider).value;
      if (session is! LoggedIn) return;

      final conn = ref.read(realtimeConnectorProvider)(
        realtimeUrl(session.server),
        session.token,
      );
      _conn = conn;
      try {
        await conn.ready;
        if (_disposed) return;
        failures = 0;
        _set(state.copyWith(status: ConnectionStatus.connected));
        // Events sent while we were disconnected are not replayed: reload what we show.
        if (connectedBefore) _resync();
        connectedBefore = true;

        await for (final text in conn.messages) {
          if (_disposed) return;
          _handle(text);
        }
        if (conn.closeCode == 4001) {
          // Session ended (logged out elsewhere or revoked): back to the login screen.
          await ref.read(sessionProvider.notifier).sessionExpired();
          return;
        }
      } on Object {
        // Could not connect. If the session is gone, stop; otherwise try again later.
        if (await _sessionGone()) return;
      } finally {
        _conn = null;
      }
      if (_disposed) return;

      _set(
        state.copyWith(
          status: ConnectionStatus.reconnecting,
          online: const {},
          typing: const {},
        ),
      );
      await _sleep(_backoff(failures++));
    }
  }

  /// Waits, but stops waiting at once if the controller is disposed (e.g. logout),
  /// so no timer is left running in the background.
  Future<void> _sleep(Duration d) {
    final wait = Completer<void>();
    _retryWait = wait;
    _retryTimer = Timer(d, wait.complete);
    return wait.future;
  }

  /// 1, 2, 4, 8, 16, then 30 seconds, plus up to 1 s of randomness, so that many
  /// clients do not all reconnect at the same moment after a server restart.
  Duration _backoff(int failures) {
    final seconds = min(30, 1 << min(failures, 5));
    return Duration(seconds: seconds, milliseconds: _random.nextInt(1000));
  }

  Future<bool> _sessionGone() async {
    try {
      await ref.read(sessionProvider.notifier).authorizedApi().me();
      return false;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await ref.read(sessionProvider.notifier).sessionExpired();
        return true;
      }
      return false;
    } on Object {
      return false; // e.g. server down: keep trying
    }
  }

  void _resync() {
    ref.read(channelsProvider.notifier).refresh();
    // The open room: the selected one, or the first room (shown when none was picked).
    final open =
        ref.read(selectedChannelProvider) ??
        ref.read(channelsProvider).value?.firstOrNull?.id;
    if (open != null && ref.exists(messagesProvider(open))) {
      ref.read(messagesProvider(open).notifier).refresh();
    }
  }

  void _handle(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    final data = json['data'];

    try {
      switch (json['type']) {
        case 'ready':
          if (data case {'online': List<Object?> list}) {
            final users = [for (final u in list) Author.fromJson(u)];
            _set(state.copyWith(online: {for (final u in users) u.id: u}));
          }
        case 'presence.updated':
          if (data case {'user': Object u, 'online': bool online}) {
            final user = Author.fromJson(u);
            final next = Map.of(state.online);
            online ? next[user.id] = user : next.remove(user.id);
            _set(state.copyWith(online: next));
          }
        case 'message.created':
          final m = Message.fromJson(data);
          ref.read(channelsProvider.notifier).applyMessage(m);
          if (ref.exists(messagesProvider(m.channelId))) {
            ref.read(messagesProvider(m.channelId).notifier).addMessage(m);
          }
          if (m.author case final a?) _stopTyping(m.channelId, a.id);
        case 'channel.created' || 'channel.updated' || 'channel.deleted':
          ref.read(channelsProvider.notifier).refresh();
        case 'typing.started':
          if (data case {'channel_id': int channelId, 'user': Object u}) {
            _startTyping(channelId, Author.fromJson(u));
          }
        // Unknown event types are ignored: newer servers may send more.
      }
    } on FormatException {
      // A malformed event is skipped; the connection stays open.
    }
  }

  void _startTyping(int channelId, Author user) {
    final next = {for (final e in state.typing.entries) e.key: Map.of(e.value)};
    (next[channelId] ??= {})[user.id] = Typist(
      user.displayName,
      clock.now().add(typingShownFor),
    );
    _set(state.copyWith(typing: next));
    _typingTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pruneTyping(),
    );
  }

  void _stopTyping(int channelId, int userId) {
    if (state.typing[channelId]?.containsKey(userId) != true) return;
    final next = {for (final e in state.typing.entries) e.key: Map.of(e.value)};
    next[channelId]!.remove(userId);
    _set(state.copyWith(typing: next));
  }

  /// Removes typing indicators older than 5 seconds.
  void _pruneTyping() {
    final now = clock.now();
    final next = <int, Map<int, Typist>>{};
    for (final e in state.typing.entries) {
      final still = {
        for (final t in e.value.entries)
          if (t.value.until.isAfter(now)) t.key: t.value,
      };
      if (still.isNotEmpty) next[e.key] = still;
    }
    if (next.isEmpty) {
      _typingTimer?.cancel();
      _typingTimer = null;
    }
    _set(state.copyWith(typing: next));
  }

  void _set(RealtimeState s) {
    if (!_disposed) state = s;
  }
}
