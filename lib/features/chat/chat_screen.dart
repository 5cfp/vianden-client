import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/session_controller.dart';
import 'chat_providers.dart';
import 'composer.dart';
import 'dialogs.dart';
import 'message_view.dart';
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
                IconButton(
                  key: const Key('refresh'),
                  tooltip: 'Check for new messages',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _refresh(context, ref),
                ),
                if (session.user.isOwner) _RoomMenu(room: room),
              ],
            ),
          ),
          Divider(color: colors.otherBubbleBorder),
          Expanded(
            child: MessageView(channelId: room.id, myUserId: session.user.id),
          ),
          Composer(channelId: room.id, roomName: room.name),
        ],
      ),
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    try {
      await Future.wait([
        ref.read(messagesProvider(room.id).notifier).refresh(),
        ref.read(channelsProvider.notifier).refresh(),
      ]);
    } on Exception catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

/// Owner tools for the open room: rename / change topic, delete.
class _RoomMenu extends ConsumerWidget {
  const _RoomMenu({required this.room});

  final Channel room;

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
              initialName: room.name,
              initialTopic: room.topic,
              save: (name, topic) =>
                  rooms.edit(room.id, name: name, topic: topic),
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
        PopupMenuItem(value: 'edit', child: Text('Rename or change topic')),
        PopupMenuItem(value: 'delete', child: Text('Delete room')),
      ],
    );
  }
}
