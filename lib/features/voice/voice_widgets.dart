import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import '../../core/session_controller.dart';
import '../../widgets/user_avatar.dart';
import '../chat/chat_providers.dart';
import 'voice_controller.dart';

/// A voice channel in the room list: its name (click to join) and who is in it.
class VoiceChannelTile extends ConsumerWidget {
  const VoiceChannelTile({
    super.key,
    required this.room,
    required this.me,
    required this.available,
  });

  final Channel room;
  final User me;

  /// Voice works on this server (GET /info).
  final bool available;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final voice = ref.watch(voiceProvider);
    final here = voice.channelId == room.id;
    final people = voice.rooms[room.id] ?? const <VoiceParticipant>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: here ? colors.selectedRoom : Colors.transparent,
          child: InkWell(
            key: Key('voice-${room.id}'),
            onTap: available && !here
                ? () => ref.read(voiceProvider.notifier).join(room.id)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.volume_up_outlined,
                    size: 18,
                    color: here ? theme.colorScheme.primary : colors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      room.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: available ? null : colors.muted,
                      ),
                    ),
                  ),
                  if (room.isPrivate)
                    Icon(Icons.lock_outline, size: 14, color: colors.muted),
                  if (!room.canSend(me.role))
                    Tooltip(
                      message: 'You can listen here, but not speak',
                      child: Icon(
                        Icons.hearing_outlined,
                        size: 14,
                        color: colors.muted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        for (final p in people)
          _ParticipantRow(
            participant: p,
            room: room,
            me: me,
            speaking: voice.speaking.contains(p.user.id),
          ),
      ],
    );
  }
}

class _ParticipantRow extends ConsumerWidget {
  const _ParticipantRow({
    required this.participant,
    required this.room,
    required this.me,
    required this.speaking,
  });

  final VoiceParticipant participant;
  final Channel room;
  final User me;
  final bool speaking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final p = participant;
    // Moderators act on people below them (same rule as the server; it checks anyway).
    final members = ref.watch(membersByIdProvider);
    final theirRole = members[p.user.id]?.role ?? Role.member;
    final canModerate =
        me.can(Permission.moderateVoice) &&
        me.role.above(theirRole) &&
        p.user.id != me.id;

    final row = Padding(
      key: Key('voice-user-${p.user.id}'),
      padding: const EdgeInsets.fromLTRB(48, 3, 16, 3),
      child: Row(
        children: [
          // A ring in the accent color while they speak.
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                width: 2,
                color: speaking
                    ? theme.colorScheme.primary
                    : Colors.transparent,
              ),
            ),
            child: MemberAvatar(
              key: speaking ? Key('speaking-${p.user.id}') : null,
              userId: p.user.id,
              fallbackName: p.user.displayName,
              size: 20,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              members[p.user.id]?.displayName ?? p.user.displayName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (p.serverMuted)
            Tooltip(
              message: 'Muted by a moderator',
              child: Icon(
                Icons.mic_off,
                key: Key('server-muted-${p.user.id}'),
                size: 15,
                color: theme.colorScheme.error,
              ),
            )
          else if (p.muted || !p.canSpeak)
            Icon(Icons.mic_off_outlined, size: 15, color: colors.muted),
          if (p.deafened)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Icons.headset_off_outlined,
                size: 15,
                color: colors.muted,
              ),
            ),
          if (canModerate)
            PopupMenuButton<String>(
              key: Key('voice-menu-${p.user.id}'),
              tooltip: 'Moderate',
              iconSize: 16,
              padding: EdgeInsets.zero,
              icon: Icon(Icons.more_vert, size: 16, color: colors.muted),
              onSelected: (choice) => _moderate(context, ref, choice),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'mute',
                  child: Text(
                    p.serverMuted ? 'Unmute for everyone' : 'Mute for everyone',
                  ),
                ),
                const PopupMenuItem(
                  value: 'disconnect',
                  child: Text('Disconnect'),
                ),
              ],
            ),
        ],
      ),
    );
    return row;
  }

  Future<void> _moderate(
    BuildContext context,
    WidgetRef ref,
    String choice,
  ) async {
    final api = ref.read(sessionProvider.notifier).authorizedApi();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (choice == 'mute') {
        await api.voiceMute(
          room.id,
          participant.user.id,
          !participant.serverMuted,
        );
      } else {
        await api.voiceDisconnect(room.id, participant.user.id);
      }
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on NetworkException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Shown above the account bar while in voice: where we are, and mute / deafen / leave.
class VoicePanel extends ConsumerWidget {
  const VoicePanel({super.key, required this.rooms});

  final List<Channel> rooms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceProvider);
    final id = voice.channelId;
    if (id == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final controller = ref.read(voiceProvider.notifier);
    final name = rooms.where((r) => r.id == id).firstOrNull?.name ?? 'Voice';
    final status = voice.phase == VoicePhase.connected
        ? 'Voice connected'
        : 'Connecting…';
    // Shown next to the channel name, so it is visible while connecting too.
    final listenOnly = !voice.canSpeak
        ? ' · listening only'
        : !voice.micAvailable
        ? ' · no microphone, listening only'
        : '';

    return Container(
      key: const Key('voice-panel'),
      padding: const EdgeInsets.fromLTRB(24, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  key: const Key('voice-status'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: voice.phase == VoicePhase.connected
                        ? theme.colorScheme.primary
                        : colors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '$name$listenOnly',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (voice.canSpeak && voice.micAvailable)
            IconButton(
              key: const Key('voice-mute'),
              tooltip: voice.muted ? 'Unmute' : 'Mute',
              icon: Icon(voice.muted ? Icons.mic_off : Icons.mic_none),
              color: voice.muted ? theme.colorScheme.error : null,
              onPressed: controller.toggleMute,
            ),
          IconButton(
            key: const Key('voice-deafen'),
            tooltip: voice.deafened ? 'Undeafen' : 'Deafen',
            icon: Icon(
              voice.deafened ? Icons.headset_off : Icons.headset_outlined,
            ),
            color: voice.deafened ? theme.colorScheme.error : null,
            onPressed: controller.toggleDeafen,
          ),
          IconButton(
            key: const Key('voice-leave'),
            tooltip: 'Leave voice',
            icon: const Icon(Icons.call_end),
            onPressed: controller.leave,
          ),
        ],
      ),
    );
  }
}
