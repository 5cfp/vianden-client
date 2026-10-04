import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/session_controller.dart';

/// Runs an API call for the logged-in user. If the server says the session is no
/// longer valid (401), the app goes back to the login screen; the error is rethrown.
Future<T> _authorized<T>(
  Ref ref,
  Future<T> Function(ApiClient api) call,
) async {
  final session = ref.read(sessionProvider.notifier);
  try {
    return await call(session.authorizedApi());
  } on ApiException catch (e) {
    if (e.isUnauthorized) await session.sessionExpired();
    rethrow;
  }
}

// ---------------------------------------------------------------------------
// Rooms
// ---------------------------------------------------------------------------

/// The room list. `autoDispose`: forgotten when the chat screen closes (e.g. logout).
final channelsProvider =
    AsyncNotifierProvider.autoDispose<ChannelsController, List<Channel>>(
      ChannelsController.new,
    );

class ChannelsController extends AsyncNotifier<List<Channel>> {
  @override
  Future<List<Channel>> build() =>
      _authorized(ref, (api) => api.listChannels());

  /// Reloads the list (new previews, rooms created by someone else).
  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => _authorized(ref, (api) => api.listChannels()),
    );
  }

  /// Owner only (the server checks). Returns the new room.
  Future<Channel> create(String name, String topic) async {
    final c = await _authorized(
      ref,
      (api) => api.createChannel(name, topic: topic),
    );
    await refresh();
    return c;
  }

  Future<void> edit(int id, {String? name, String? topic}) async {
    await _authorized(
      ref,
      (api) => api.updateChannel(id, name: name, topic: topic),
    );
    await refresh();
  }

  Future<void> delete(int id) async {
    await _authorized(ref, (api) => api.deleteChannel(id));
    await refresh();
  }
}

/// The room the user is looking at. null = none chosen yet (the screen then picks the first).
final selectedChannelProvider =
    NotifierProvider.autoDispose<SelectedChannel, int?>(SelectedChannel.new);

class SelectedChannel extends Notifier<int?> {
  @override
  int? build() => null;

  void select(int? id) => state = id;
}

// ---------------------------------------------------------------------------
// Messages of one room
// ---------------------------------------------------------------------------

/// What the message view shows for one room.
class MessagesState {
  const MessagesState({
    required this.messages,
    required this.hasMore,
    this.loadingOlder = false,
  });

  /// Oldest first.
  final List<Message> messages;

  /// Whether older messages exist on the server.
  final bool hasMore;

  /// True while an older page is being fetched.
  final bool loadingOlder;

  MessagesState copyWith({
    List<Message>? messages,
    bool? hasMore,
    bool? loadingOlder,
  }) => MessagesState(
    messages: messages ?? this.messages,
    hasMore: hasMore ?? this.hasMore,
    loadingOlder: loadingOlder ?? this.loadingOlder,
  );
}

/// Messages per room: `ref.watch(messagesProvider(channelId))`.
/// A "family" provider: one independent state per argument (here, per room id).
final messagesProvider = AsyncNotifierProvider.autoDispose
    .family<MessagesController, MessagesState, int>(MessagesController.new);

class MessagesController extends AsyncNotifier<MessagesState> {
  MessagesController(this.channelId);

  final int channelId;

  static const pageSize = 50;

  @override
  Future<MessagesState> build() async {
    final page = await _authorized(
      ref,
      (api) => api.listMessages(channelId, limit: pageSize),
    );
    return MessagesState(messages: page.messages, hasMore: page.hasMore);
  }

  /// Loads the page before the oldest message we have (called when scrolling up).
  Future<void> loadOlder() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingOlder) return;
    state = AsyncData(current.copyWith(loadingOlder: true));

    try {
      final page = await _authorized(
        ref,
        (api) => api.listMessages(
          channelId,
          before: current.messages.first.id,
          limit: pageSize,
        ),
      );
      if (!ref.mounted) return;
      state = AsyncData(
        MessagesState(
          messages: [...page.messages, ...current.messages],
          hasMore: page.hasMore,
        ),
      );
    } on Exception {
      if (!ref.mounted) return;
      // Keep what we have; the user can scroll up again to retry.
      state = AsyncData(current.copyWith(loadingOlder: false));
    }
  }

  /// Fetches the newest page again and merges it in (the "refresh" button; live updates come in M3).
  Future<void> refresh() async {
    final current = state.value;
    final page = await _authorized(
      ref,
      (api) => api.listMessages(channelId, limit: pageSize),
    );
    if (!ref.mounted) return;
    if (current == null) {
      state = AsyncData(
        MessagesState(messages: page.messages, hasMore: page.hasMore),
      );
      return;
    }
    state = AsyncData(
      current.copyWith(messages: _merge(current.messages, page.messages)),
    );
  }

  /// Sends a message and shows it right away. Throws on failure so the composer can keep the text.
  Future<void> send(String content) async {
    final sent = await _authorized(
      ref,
      (api) => api.sendMessage(channelId, content),
    );
    if (!ref.mounted) return;
    final current = state.value;
    if (current != null) {
      state = AsyncData(
        current.copyWith(messages: _merge(current.messages, [sent])),
      );
    }
    ref
        .read(channelsProvider.notifier)
        .refresh(); // update the room list preview
  }

  /// Combines two oldest-first lists without duplicates, sorted by id (= send order).
  static List<Message> _merge(List<Message> a, List<Message> b) {
    final byId = {for (final m in a) m.id: m, for (final m in b) m.id: m};
    return byId.values.toList()..sort((x, y) => x.id.compareTo(y.id));
  }
}
