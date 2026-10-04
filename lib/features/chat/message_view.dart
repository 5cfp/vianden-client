import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import 'chat_providers.dart';
import 'dialogs.dart';
import 'time_format.dart';

/// The scrolling message history of one room. Newest at the bottom; scrolling up loads older pages.
class MessageView extends ConsumerStatefulWidget {
  const MessageView({super.key, required this.channelId, required this.me});

  final int channelId;

  /// The logged-in user: for "mine" and for the moderation actions.
  final User me;

  @override
  ConsumerState<MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends ConsumerState<MessageView> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// The list is "reversed" (offset 0 = the bottom), so the TOP is maxScrollExtent.
  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
      ref.read(messagesProvider(widget.channelId).notifier).loadOlder();
    }
  }

  Future<void> _delete(Message m) async {
    if (!await confirmDeleteMessage(context, m)) return;
    try {
      await ref.read(messagesProvider(widget.channelId).notifier).delete(m.id);
    } on ApiException catch (e) {
      _showError(e.message);
    } on NetworkException catch (e) {
      _showError(e.message);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(messagesProvider(widget.channelId));

    return switch (state) {
      AsyncData(:final value) => _buildList(context, value),
      AsyncError() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Could not load messages.'),
            const SizedBox(height: AppSpacing.small),
            OutlinedButton(
              onPressed: () =>
                  ref.invalidate(messagesProvider(widget.channelId)),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _buildList(BuildContext context, MessagesState s) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final messages = s.messages;
    final me = widget.me;

    // Moderators can delete messages of members BELOW their role. The member list
    // tells us each author's role (only loaded for users who can delete at all).
    final canDeleteAny = me.can(Permission.deleteMessages);
    final roles = canDeleteAny
        ? {
            for (final m
                in ref.watch(membersProvider).value ?? const <Member>[])
              m.id: m.role,
          }
        : const <int, Role>{};
    bool canDelete(Message m) {
      if (!canDeleteAny || m.deleted) return false;
      final author = m.author;
      if (author == null) return true; // deleted account: below everyone
      if (author.id == me.id) return false;
      // Unknown role (list still loading): show it; the server decides anyway.
      final role = roles[author.id];
      return role == null || me.role.above(role);
    }

    // If the first page does not fill the screen there is nothing to scroll, so the
    // scroll listener would never ask for older messages: check after this frame.
    if (s.hasMore && !s.loadingOlder) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _onScroll();
      });
    }

    if (messages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet. Say hi!',
          key: const Key('empty-room'),
          style: theme.textTheme.bodyLarge?.copyWith(color: colors.muted),
        ),
      );
    }

    // At the top of the history: a spinner while older pages exist, else a note.
    final header = s.hasMore
        ? const Padding(
            padding: EdgeInsets.all(AppSpacing.medium),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        : Padding(
            padding: const EdgeInsets.all(AppSpacing.medium),
            child: Center(
              child: Text(
                'This is the start of the room.',
                style: theme.textTheme.bodySmall?.copyWith(color: colors.muted),
              ),
            ),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBubble = constraints.maxWidth * 0.7;
        return ListView.builder(
          key: const Key('messages'),
          controller: _scroll,
          reverse: true, // starts at the bottom, like every chat app
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          itemCount: messages.length + 1,
          itemBuilder: (context, i) {
            if (i == messages.length) return header;
            // reverse: index 0 is the NEWEST message.
            final index = messages.length - 1 - i;
            final m = messages[index];
            final prev = index > 0 ? messages[index - 1] : null;

            final newDay =
                prev == null || !sameDay(prev.createdAt, m.createdAt);
            // Consecutive messages from the same person within 5 minutes share one name line.
            final grouped =
                !newDay &&
                prev.author?.id == m.author?.id &&
                m.createdAt.difference(prev.createdAt) <
                    const Duration(minutes: 5);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (newDay) _DaySeparator(m.createdAt),
                _Bubble(
                  message: m,
                  mine: m.author?.id == me.id,
                  showHeader: !grouped,
                  maxWidth: maxBubble,
                  onDelete: canDelete(m) ? () => _delete(m) : null,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator(this.time);
  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final line = Expanded(child: Divider(color: colors.otherBubbleBorder));

    // ──────── Today ────────
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Row(
        children: [
          line,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              dayLabel(time),
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          line,
        ],
      ),
    );
  }
}

class _Bubble extends StatefulWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.showHeader,
    required this.maxWidth,
    this.onDelete,
  });

  final Message message;
  final bool mine;
  final bool showHeader;
  final double maxWidth;

  /// Set when the user may delete this message (moderation).
  final VoidCallback? onDelete;

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
  /// The delete button only shows while the mouse is over the message.
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final message = widget.message;
    final mine = widget.mine;
    final showHeader = widget.showHeader;
    final maxWidth = widget.maxWidth;
    final time = hourMinute(message.createdAt);

    final Widget bubble = message.deleted
        // The text is gone on the server too; only this placeholder remains.
        ? Container(
            key: Key('deleted-${message.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: colors.otherBubbleBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Message deleted',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.muted,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        : Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: mine ? colors.ownBubble : colors.otherBubble,
              border: mine ? null : Border.all(color: colors.otherBubbleBorder),
              // The corner nearest the sender stays sharp.
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(mine ? 12 : 4),
                topRight: Radius.circular(mine ? 4 : 12),
                bottomLeft: const Radius.circular(12),
                bottomRight: const Radius.circular(12),
              ),
            ),
            // Plain text only: the content is displayed exactly as typed, never as markup or links.
            child: SelectableText(
              message.content,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: mine ? colors.onOwnBubble : theme.colorScheme.onSurface,
                height: 1.45,
              ),
            ),
          );

    return Padding(
      padding: EdgeInsets.only(top: showHeader ? 12 : 4),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (showHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text.rich(
                TextSpan(
                  children: [
                    if (!mine)
                      TextSpan(
                        text:
                            '${message.author?.displayName ?? 'Deleted user'}  ',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    TextSpan(
                      text: time,
                      style: TextStyle(color: colors.muted),
                    ),
                  ],
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (widget.onDelete == null)
            bubble
          else
            MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: bubble),
                  // Faded out (not removed) when not hovered, so its place does not jump.
                  AnimatedOpacity(
                    opacity: _hovered ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: IconButton(
                      key: Key('delete-message-${message.id}'),
                      tooltip: 'Delete message',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      color: colors.muted,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: widget.onDelete,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
