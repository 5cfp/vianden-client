import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
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

  /// Updates a room's last-message preview from a live event (no server request).
  void applyMessage(Message m) {
    final rooms = state.value;
    if (rooms == null) return;
    final content = m.content.characters.length > 100
        ? '${m.content.characters.take(100)}…' // same rule as the server
        : m.content;
    state = AsyncData([
      for (final r in rooms)
        r.id == m.channelId
            ? Channel(
                id: r.id,
                name: r.name,
                topic: r.topic,
                position: r.position,
                lastMessage: MessagePreview(
                  authorName: m.author?.displayName ?? '',
                  content: content,
                  createdAt: m.createdAt,
                ),
              )
            : r,
    ]);
  }

  /// Owner only (the server checks). Returns the new room.
  Future<Channel> create(
    String name,
    String topic, {
    Role viewRole = Role.member,
    Role sendRole = Role.member,
  }) async {
    final c = await _authorized(
      ref,
      (api) => api.createChannel(
        name,
        topic: topic,
        viewRole: viewRole,
        sendRole: sendRole,
      ),
    );
    await refresh();
    return c;
  }

  Future<void> edit(
    int id, {
    String? name,
    String? topic,
    Role? viewRole,
    Role? sendRole,
  }) async {
    await _authorized(
      ref,
      (api) => api.updateChannel(
        id,
        name: name,
        topic: topic,
        viewRole: viewRole,
        sendRole: sendRole,
      ),
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

  /// Shows a message as deleted (a live event, or our own action). Replies that
  /// quote it now say "Original message deleted".
  void markDeleted(int messageId) {
    final m = state.value?.messages.where((m) => m.id == messageId).firstOrNull;
    if (m != null) applyUpdate(m.asDeleted());
  }

  /// Replaces a message with a newer version (edited or deleted), and refreshes the
  /// quotes of replies to it. Ignored if we do not have it loaded.
  void applyUpdate(Message updated) {
    final current = state.value;
    if (current == null || !current.messages.any((m) => m.id == updated.id)) {
      return;
    }
    state = AsyncData(
      current.copyWith(
        messages: [
          for (final m in current.messages)
            m.id == updated.id ? updated : m.withQuoteOf(updated),
        ],
      ),
    );
  }

  /// Changes the text of one of our own messages.
  Future<void> edit(int messageId, String content) async {
    final edited = await _authorized(
      ref,
      (api) => api.editMessage(channelId, messageId, content),
    );
    if (!ref.mounted) return;
    applyUpdate(edited);
    ref.read(channelsProvider.notifier).refresh(); // the preview may change
  }

  /// Deletes a message: our own, or someone's as a moderator (the server checks).
  Future<void> delete(int messageId) async {
    await _authorized(ref, (api) => api.deleteMessage(channelId, messageId));
    if (!ref.mounted) return;
    markDeleted(messageId);
    ref.read(channelsProvider.notifier).refresh(); // the preview may change
  }

  /// Adds a message that arrived live (ignored if we already have it).
  void addMessage(Message m) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(messages: _merge(current.messages, [m])),
    );
  }

  /// Sends a message and shows it right away. Throws on failure so the composer can keep the text.
  Future<void> send(String content, {int? replyTo}) async {
    final sent = await _authorized(
      ref,
      (api) => api.sendMessage(channelId, content, replyTo: replyTo),
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

// ---------------------------------------------------------------------------
// Composer mode: replying to or editing a message (M6)
// ---------------------------------------------------------------------------

/// What the composer of a room is doing besides writing a new message.
/// `sealed`: these are all the possible modes (see the AppState comment).
sealed class ComposerMode {
  const ComposerMode();
}

class Writing extends ComposerMode {
  const Writing();
}

class ReplyingTo extends ComposerMode {
  const ReplyingTo(this.message);
  final Message message;
}

class Editing extends ComposerMode {
  const Editing(this.message);
  final Message message;
}

/// Per room: `ref.watch(composerModeProvider(channelId))`.
final composerModeProvider = NotifierProvider.autoDispose
    .family<ComposerModeController, ComposerMode, int>(
      ComposerModeController.new,
    );

class ComposerModeController extends Notifier<ComposerMode> {
  ComposerModeController(this.channelId);

  final int channelId;

  @override
  ComposerMode build() => const Writing();

  void replyTo(Message m) => state = ReplyingTo(m);
  void edit(Message m) => state = Editing(m);
  void cancel() => state = const Writing();
}

// ---------------------------------------------------------------------------
// Members (M5)
// ---------------------------------------------------------------------------

/// The member list, with roles (and ban details for users who may ban).
final membersProvider =
    AsyncNotifierProvider.autoDispose<MembersController, List<Member>>(
      MembersController.new,
    );

class MembersController extends AsyncNotifier<List<Member>> {
  @override
  Future<List<Member>> build() => _authorized(ref, (api) => api.listMembers());

  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => _authorized(ref, (api) => api.listMembers()),
    );
  }

  Future<void> setRole(int userId, Role role) async {
    await _authorized(ref, (api) => api.setRole(userId, role));
    await refresh();
  }

  Future<void> kick(int userId) => _authorized(ref, (api) => api.kick(userId));

  Future<void> ban(int userId, String reason) async {
    await _authorized(ref, (api) => api.ban(userId, reason: reason));
    await refresh();
  }

  Future<void> unban(int userId) async {
    await _authorized(ref, (api) => api.unban(userId));
    await refresh();
  }

  /// A live member.updated event: update that member's role in place.
  void applyUpdate(Member updated) {
    final list = state.value;
    if (list == null) return;
    state = AsyncData([
      for (final m in list)
        m.id == updated.id
            ? Member(
                id: m.id,
                username: updated.username,
                displayName: updated.displayName,
                role: updated.role,
                banned: m.banned,
                banReason: m.banReason,
              )
            : m,
    ]);
  }
}
