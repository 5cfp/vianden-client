import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import '../../core/session_controller.dart';
import 'chat_providers.dart';
import 'composer.dart';
import 'dialogs.dart';
import 'message_view.dart';
import 'realtime_controller.dart';
import 'room_list.dart';

/// The main screen when logged in: rooms on the left, the open room on the right.
/// On a narrow window it shows one of the two at a time.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.session});

  final LoggedIn session;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  /// Narrow layout only: true while a room is open (instead of the room list).
  bool _roomOpen = false;

  static const _wideLayout = 720.0;

  @override
  Widget build(BuildContext context) {
    // Watching the realtime provider opens the live connection and keeps it open
    // for as long as this screen is shown.
    ref.watch(realtimeProvider);
    final rooms = ref.watch(channelsProvider).value ?? const <Channel>[];
    final selectedId = ref.watch(selectedChannelProvider);

    // Pick the first room by default, and fall back to it if the open room was deleted.
    final room =
        rooms.where((r) => r.id == selectedId).firstOrNull ?? rooms.firstOrNull;

    final roomList = RoomList(
      session: widget.session,
      onOpen: (_) => setState(() => _roomOpen = true),
    );
    final roomPane = room == null
        ? const SizedBox.shrink()
        : _RoomPane(
            key: ValueKey(room.id), // a fresh pane (and composer) per room
            room: room,
            session: widget.session,
            onBack: () => setState(() => _roomOpen = false),
          );

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _wideLayout) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 290, child: roomList),
                const VerticalDivider(width: 1),
                Expanded(child: roomPane),
              ],
            );
          }
          return _roomOpen && room != null ? roomPane : roomList;
        },
      ),
    );
  }
}

class _RoomPane extends ConsumerWidget {
  const _RoomPane({
    super.key,
    required this.room,
    required this.session,
    required this.onBack,
  });

  final Channel room;
  final LoggedIn session;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final narrow = MediaQuery.sizeOf(context).width < 720;

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(narrow ? 8 : 32, 22, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (narrow)
                  IconButton(
                    tooltip: 'Rooms',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: onBack,
                  ),
                // Name + topic fill all the space left of the buttons, so the
                // buttons always sit at the far right edge.
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          room.name,
                          key: const Key('room-title'),
                          style: theme.textTheme.headlineMedium?.copyWith(
                            height: 1,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (room.topic.isNotEmpty) ...[
                        const SizedBox(width: 14),
                        Flexible(
                          child: Text(
                            room.topic,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.muted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Managers can edit rooms up to their own role (the server checks it too).
                if (session.user.can(Permission.manageChannels) &&
                    session.user.role.atLeast(room.sendRole))
                  _RoomMenu(room: room, myRole: session.user.role),
              ],
            ),
          ),
          Divider(color: colors.otherBubbleBorder),
          const _ConnectionBanner(),
          Expanded(
            child: MessageView(
              channelId: room.id,
              me: session.user,
              canWrite: room.canSend(session.user.role),
            ),
          ),
          _TypingLine(channelId: room.id),
          if (room.canSend(session.user.role))
            Composer(channelId: room.id, roomName: room.name)
          else
            _ReadOnlyNotice(room: room),
        ],
      ),
    );
  }
}

/// A thin bar while the live connection is down (it reconnects by itself).
class _ConnectionBanner extends ConsumerWidget {
  const _ConnectionBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(realtimeProvider.select((s) => s.status));
    if (status != ConnectionStatus.reconnecting) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      key: const Key('reconnecting'),
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Connection lost. Reconnecting…',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// "Sara is typing…" above the composer. Always takes the same height, so nothing jumps.
class _TypingLine extends ConsumerWidget {
  const _TypingLine({required this.channelId});

  final int channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(
      realtimeProvider.select((s) => s.typingIn(channelId)),
    );
    final theme = Theme.of(context);
    final text = switch (names) {
      [] => '',
      [final a] => '$a is typing…',
      [final a, final b] => '$a and $b are typing…',
      _ => 'Several people are typing…',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 2),
      child: SizedBox(
        height: 18,
        child: Text(
          text,
          key: const Key('typing'),
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.extension<ChatColors>()!.muted,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

/// Room tools for managers: edit (name, topic, access), delete.
class _RoomMenu extends ConsumerWidget {
  const _RoomMenu({required this.room, required this.myRole});

  final Channel room;
  final Role myRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.read(channelsProvider.notifier);

    return PopupMenuButton<String>(
      key: const Key('room-menu'),
      tooltip: 'Room settings',
      icon: const Icon(Icons.more_vert),
      onSelected: (choice) async {
        switch (choice) {
          case 'edit':
            await showRoomDialog(
              context,
              title: 'Edit room',
              actionLabel: 'Save',
              myRole: myRole,
              initial: room,
              // Access fields are sent only when changed.
              save: (s) => rooms.edit(
                room.id,
                name: s.name,
                topic: s.topic,
                viewRole: s.viewRole == room.viewRole ? null : s.viewRole,
                sendRole: s.sendRole == room.sendRole ? null : s.sendRole,
              ),
            );
          case 'delete':
            if (!await confirmDeleteRoom(context, room)) return;
            try {
              await rooms.delete(room.id);
            } on ApiException catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            }
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: Text('Edit room')),
        PopupMenuItem(value: 'delete', child: Text('Delete room')),
      ],
    );
  }
}

/// Shown instead of the composer in rooms where this user may only read.
class _ReadOnlyNotice extends StatelessWidget {
  const _ReadOnlyNotice({required this.room});

  final Channel room;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const Key('read-only'),
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 20),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          'Only ${room.sendRole.label}s and up can write in this room.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.extension<ChatColors>()!.muted,
          ),
        ),
      ),
    );
  }
}
