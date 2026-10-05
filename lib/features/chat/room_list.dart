import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_config.dart';
import '../../app_config/app_theme.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import '../../core/session_controller.dart';
import 'chat_providers.dart';
import '../../widgets/about.dart';
import '../../widgets/release_badge.dart';
import '../../widgets/user_avatar.dart';
import 'dialogs.dart';
import 'members_dialog.dart';
import 'profile_dialog.dart';
import '../voice/audio_settings_dialog.dart';
import '../voice/voice_widgets.dart';
import 'realtime_controller.dart';
import 'time_format.dart';

/// Left column: server name, rooms (messenger style, with last-message previews), and the account bar.
class RoomList extends ConsumerWidget {
  const RoomList({super.key, required this.session, required this.onOpen});

  final LoggedIn session;

  /// Called when a room is tapped (the narrow layout uses it to switch to the chat).
  final void Function(int roomId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final rooms = ref.watch(channelsProvider);
    final selected = ref.watch(selectedChannelProvider);
    final user = session.user;

    return ColoredBox(
      color: colors.roomList,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.info.name,
                  key: const Key('server-name'),
                  style: theme.textTheme.headlineMedium?.copyWith(height: 1.05),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                const _OnlineLine(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Rooms',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Shown only with the permission; the server enforces it anyway.
                if (user.can(Permission.manageChannels))
                  IconButton(
                    key: const Key('new-room'),
                    tooltip: 'New room',
                    icon: const Icon(Icons.add),
                    onPressed: () => showRoomDialog(
                      context,
                      title: 'New room',
                      actionLabel: 'Create room',
                      myRole: user.role,
                      allowVoice: session.info.voice,
                      save: (s) async {
                        final room = await ref
                            .read(channelsProvider.notifier)
                            .create(
                              s.name,
                              s.topic,
                              viewRole: s.viewRole,
                              sendRole: s.sendRole,
                              type: s.type,
                            );
                        // Voice rooms are joined from the list, not opened.
                        if (room.isVoice) return;
                        ref
                            .read(selectedChannelProvider.notifier)
                            .select(room.id);
                        onOpen(room.id);
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: switch (rooms) {
              AsyncData(:final value) => ListView(
                children: [
                  for (final room in value.where((r) => !r.isVoice))
                    _RoomTile(
                      room: room,
                      selected: room.id == selected,
                      onTap: () {
                        ref
                            .read(selectedChannelProvider.notifier)
                            .select(room.id);
                        onOpen(room.id);
                      },
                    ),
                  if (value.any((r) => r.isVoice)) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
                      child: Text(
                        session.info.voice
                            ? 'Voice'
                            : 'Voice (not available on this server)',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.muted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    for (final room in value.where((r) => r.isVoice))
                      VoiceChannelTile(
                        room: room,
                        me: user,
                        available: session.info.voice,
                      ),
                  ],
                ],
              ),
              AsyncError() => _LoadError(
                onRetry: () => ref.read(channelsProvider.notifier).refresh(),
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ReleaseBadge(),
            ),
          ),
          VoicePanel(rooms: rooms.value ?? const []),
          Divider(color: colors.line),
          _AccountBar(session: session),
        ],
      ),
    );
  }
}

/// "3 online" under the server name; hovering shows who. "Reconnecting…" while the connection is down.
class _OnlineLine extends ConsumerWidget {
  const _OnlineLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.extension<ChatColors>()!.muted,
    );
    final live = ref.watch(realtimeProvider);
    if (live.status != ConnectionStatus.connected) {
      return Text('${AppConfig.appName} · connecting…', style: muted);
    }
    final names = live.online.values.map((u) => u.displayName).toList()..sort();
    return Tooltip(
      message: names.join(', '),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${names.length} online',
            key: const Key('online-count'),
            style: muted,
          ),
        ],
      ),
    );
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({
    required this.room,
    required this.selected,
    required this.onTap,
  });

  final Channel room;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final last = room.lastMessage;
    // The open room never shows badges (what is on screen is being read).
    final unread = !selected && room.unreadCount > 0;
    // A message with only files has no text: say so instead of showing nothing.
    final text = last == null || last.content.isNotEmpty
        ? last?.content
        : 'Sent a file';
    final preview = switch (last) {
      null => room.topic.isEmpty ? 'No messages yet' : room.topic,
      MessagePreview(authorName: '') => text!,
      _ => '${last.authorName}: $text',
    };

    return Material(
      color: selected ? colors.selectedRoom : Colors.transparent,
      child: InkWell(
        key: Key('room-${room.id}'),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.fromLTRB(21, 10, 24, 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                width: 3,
                color: selected
                    ? theme.colorScheme.primary
                    : Colors.transparent,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      room.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: unread ? FontWeight.w900 : FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Small hints for rooms with limited access.
                  if (room.isPrivate)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Tooltip(
                        message:
                            'Only ${room.viewRole.label}s and up can see this room',
                        child: Icon(
                          Icons.lock_outline,
                          key: Key('room-private-${room.id}'),
                          size: 14,
                          color: colors.muted,
                        ),
                      ),
                    )
                  else if (room.isReadOnlyForMembers)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Tooltip(
                        message:
                            'Only ${room.sendRole.label}s and up can write here',
                        child: Icon(
                          Icons.campaign_outlined,
                          key: Key('room-readonly-${room.id}'),
                          size: 14,
                          color: colors.muted,
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (last != null)
                    Text(
                      shortWhen(last.createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.muted,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      // Previews are one line: newlines in the message would break the layout.
                      preview.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: unread
                            ? theme.colorScheme.onSurface
                            : colors.muted,
                      ),
                    ),
                  ),
                  if (unread) _UnreadBadge(room: room),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountBar extends ConsumerWidget {
  const _AccountBar({required this.session});

  final LoggedIn session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final user = session.user;
    final controller = ref.read(sessionProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
      child: Row(
        children: [
          UserAvatar(name: user.displayName, avatar: user.avatar),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  user.role == Role.member
                      ? '@${user.username}'
                      : user.role.label.toLowerCase(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            key: const Key('account-menu'),
            tooltip: 'Account',
            icon: const Icon(Icons.more_horiz),
            onSelected: (choice) {
              switch (choice) {
                case 'invite':
                  showInviteDialog(
                    context,
                    () => controller.authorizedApi().createInvite(),
                  );
                case 'profile':
                  showProfileDialog(context);
                case 'audio':
                  showAudioSettingsDialog(context);
                case 'members':
                  showMembersDialog(context, user);
                case 'server':
                  controller.changeServer();
                case 'logout':
                  controller.logout();
                case 'about':
                  showAbout(context);
              }
            },
            itemBuilder: (_) => [
              if (user.can(Permission.manageInvites))
                const PopupMenuItem(
                  value: 'invite',
                  child: Text('Invite a friend'),
                ),
              const PopupMenuItem(value: 'profile', child: Text('Profile')),
              const PopupMenuItem(value: 'members', child: Text('Members')),
              const PopupMenuItem(value: 'audio', child: Text('Voice & audio')),
              const PopupMenuItem(
                value: 'server',
                child: Text('Change server'),
              ),
              const PopupMenuItem(
                value: 'about',
                child: Text('About & licenses'),
              ),
              const PopupMenuItem(value: 'logout', child: Text('Log out')),
            ],
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Could not load rooms.'),
          const SizedBox(height: AppSpacing.small),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

/// "3" for unread messages, or "@2" (accent color) when some of them mention you.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.room});

  final Channel room;

  static String _count(int n) => n >= 100 ? '99+' : '$n';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mentions = room.mentionCount > 0;
    return Container(
      key: Key('unread-${room.id}'),
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: mentions
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        mentions ? '@${_count(room.mentionCount)}' : _count(room.unreadCount),
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: mentions
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}
