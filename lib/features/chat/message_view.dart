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
  const MessageView({
    super.key,
    required this.channelId,
    required this.me,
    required this.canWrite,
  });

  final int channelId;

  /// The logged-in user: for "mine" and for the moderation actions.
  final User me;

  /// Whether the user may write in this room (reply and edit need it).
  final bool canWrite;

  @override
  ConsumerState<MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends ConsumerState<MessageView> {
  final _scroll = ScrollController();

  /// One key per message, so we can find a message's widget to scroll to it.
  final _keys = <int, GlobalKey>{};

  /// The message we just jumped to (it lights up briefly); the counter restarts the
  /// animation when jumping to the same message twice.
  int? _highlightId;
  int _highlightCount = 0;

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

  MessagesController get _messages =>
      ref.read(messagesProvider(widget.channelId).notifier);

  /// The list is "reversed" (offset 0 = the bottom), so the TOP is maxScrollExtent.
  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
      _messages.loadOlder();
    }
  }

  /// Scrolls to the message a reply quotes. The list only builds the messages near the
  /// screen, so we scroll up step by step until the original's widget exists (scrolling
  /// up also loads older pages), then center it and light it up.
  Future<void> _jumpTo(int id) async {
    for (var step = 0; step < 100 && mounted; step++) {
      final target = _keys[id]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
        );
        if (mounted) {
          setState(() {
            _highlightId = id;
            _highlightCount++;
          });
        }
        return;
      }
      final s = ref.read(messagesProvider(widget.channelId)).value;
      if (s == null || !_scroll.hasClients) return;
      final pos = _scroll.position;
      final atTop = pos.pixels >= pos.maxScrollExtent;
      if (atTop && !s.hasMore) break; // whole history loaded: it is gone
      if (atTop) {
        await _messages.loadOlder(); // the next page makes room to scroll
      } else {
        _scroll.jumpTo(
          (pos.pixels + pos.viewportDimension * 0.8).clamp(
            0,
            pos.maxScrollExtent,
          ),
        );
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    _showError('Could not find the original message.');
  }

  Future<void> _delete(Message m) async {
    if (!await confirmDeleteMessage(context, m)) return;
    try {
      await _messages.delete(m.id);
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
    final mode = ref.read(composerModeProvider(widget.channelId).notifier);

    // Moderators can delete messages of members BELOW their role. The member list
    // tells us each author's role (only loaded for users who can delete at all).
    final canModerate = me.can(Permission.deleteMessages);
    final roles = canModerate
        ? {
            for (final m
                in ref.watch(membersProvider).value ?? const <Member>[])
              m.id: m.role,
          }
        : const <int, Role>{};
    bool canDelete(Message m) {
      if (m.deleted) return false;
      final author = m.author;
      if (author?.id == me.id) return true; // your own: always
      if (!canModerate) return false;
      if (author == null) return true; // deleted account: below everyone
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
            final mine = m.author?.id == me.id;
            final live = !m.deleted;

            final newDay =
                prev == null || !sameDay(prev.createdAt, m.createdAt);
            // Consecutive messages from the same person within 5 minutes share one
            // name line. A reply always gets its own (its quote sits above it).
            final grouped =
                !newDay &&
                m.replyTo == null &&
                prev.author?.id == m.author?.id &&
                m.createdAt.difference(prev.createdAt) <
                    const Duration(minutes: 5);

            return KeyedSubtree(
              key: _keys.putIfAbsent(m.id, GlobalKey.new),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (newDay) _DaySeparator(m.createdAt),
                  _Bubble(
                    message: m,
                    mine: mine,
                    showHeader: !grouped,
                    maxWidth: maxBubble,
                    highlight: m.id == _highlightId ? _highlightCount : null,
                    onQuoteTap: m.replyTo == null
                        ? null
                        : () => _jumpTo(m.replyTo!.id),
                    onReply: widget.canWrite && live
                        ? () => mode.replyTo(m)
                        : null,
                    onEdit: widget.canWrite && live && mine
                        ? () => mode.edit(m)
                        : null,
                    onDelete: canDelete(m) ? () => _delete(m) : null,
                  ),
                ],
              ),
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
    this.highlight,
    this.onQuoteTap,
    this.onReply,
    this.onEdit,
    this.onDelete,
  });

  final Message message;
  final bool mine;
  final bool showHeader;
  final double maxWidth;

  /// Non-null right after jumping to this message: it lights up and fades out.
  final int? highlight;

  final VoidCallback? onQuoteTap;

  /// Each action is null when the user may not do it (then its button is hidden).
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
  /// The action buttons only show while the mouse is over the message.
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final message = widget.message;
    final mine = widget.mine;
    final time = hourMinute(message.createdAt);
    final textColor = mine ? colors.onOwnBubble : theme.colorScheme.onSurface;

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
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
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
            child: SelectableText.rich(
              TextSpan(
                text: message.content,
                children: [
                  if (message.editedAt != null)
                    TextSpan(
                      text: '  (edited)',
                      style: TextStyle(
                        fontSize: 11,
                        color: textColor.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
              key: Key('message-${message.id}'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: textColor,
                height: 1.45,
              ),
            ),
          );

    final actions = [
      if (widget.onReply case final onReply?)
        _action('reply', Icons.reply, 'Reply', onReply),
      if (widget.onEdit case final onEdit?)
        _action('edit', Icons.edit_outlined, 'Edit', onEdit),
      if (widget.onDelete case final onDelete?)
        _action('delete', Icons.delete_outline, 'Delete', onDelete),
    ];

    Widget body = bubble;
    if (actions.isNotEmpty) {
      // Faded out (not removed) when not hovered, so nothing jumps around.
      final bar = AnimatedOpacity(
        opacity: _hovered ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: Row(mainAxisSize: MainAxisSize.min, children: actions),
      );
      body = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          // Actions on the inner side: right of others' bubbles, left of mine.
          children: mine
              ? [bar, Flexible(child: bubble)]
              : [Flexible(child: bubble), bar],
        ),
      );
    }

    final content = Padding(
      padding: EdgeInsets.only(top: widget.showHeader ? 12 : 4),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (message.replyTo case final quote?)
            _Quote(
              quote: quote,
              mine: mine,
              maxWidth: widget.maxWidth,
              onTap: widget.onQuoteTap,
            ),
          if (widget.showHeader)
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
          body,
        ],
      ),
    );

    final highlight = widget.highlight;
    if (highlight == null) return content;
    // Just jumped here: a soft background that fades out over 2 seconds.
    return TweenAnimationBuilder<double>(
      key: ValueKey(highlight),
      tween: Tween(begin: 1, end: 0),
      duration: const Duration(seconds: 2),
      builder: (context, t, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.15 * t),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
      child: content,
    );
  }

  Widget _action(String id, IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      key: Key('$id-message-${widget.message.id}'),
      tooltip: tip,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      color: Theme.of(context).extension<ChatColors>()!.muted,
      icon: Icon(icon),
      onPressed: onTap,
    );
  }
}

/// The quote above a reply: a curved line, the original author, and a one-line
/// excerpt. Tapping it jumps to the original.
class _Quote extends StatelessWidget {
  const _Quote({
    required this.quote,
    required this.mine,
    required this.maxWidth,
    this.onTap,
  });

  final ReplyQuote quote;
  final bool mine;
  final double maxWidth;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final style = theme.textTheme.bodySmall?.copyWith(color: colors.muted);
    final side = BorderSide(color: colors.otherBubbleBorder, width: 2);

    // ╭── the "elbow" that connects the quote to the message below it.
    final elbow = Container(
      width: 18,
      height: 10,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(
          top: side,
          left: mine ? BorderSide.none : side,
          right: mine ? side : BorderSide.none,
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(mine ? 0 : 6),
          topRight: Radius.circular(mine ? 6 : 0),
        ),
      ),
    );

    final text = Flexible(
      child: Text.rich(
        quote.deleted
            ? const TextSpan(
                text: 'Original message deleted',
                style: TextStyle(fontStyle: FontStyle.italic),
              )
            : TextSpan(
                children: [
                  TextSpan(
                    text: '${quote.author?.displayName ?? 'Deleted user'}  ',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  // One line: line breaks in the original would break the layout.
                  TextSpan(text: quote.content.replaceAll('\n', ' ')),
                ],
              ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: MouseRegion(
          cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: GestureDetector(
            key: Key('quote-${quote.id}'),
            onTap: onTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: mine
                  ? [text, const SizedBox(width: 6), elbow]
                  : [
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: elbow,
                      ),
                      const SizedBox(width: 6),
                      text,
                    ],
            ),
          ),
        ),
      ),
    );
  }
}
