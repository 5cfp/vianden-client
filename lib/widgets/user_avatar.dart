import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_config/app_theme.dart';
import '../features/chat/chat_providers.dart';

/// A user's picture: their avatar if they have one, otherwise the first letter of
/// their name on a colored square. [avatar] is the URL path from a user/member object.
class UserAvatar extends ConsumerWidget {
  const UserAvatar({
    super.key,
    required this.name,
    required this.avatar,
    this.size = 34,
  });

  final String name;
  final String? avatar;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<ChatColors>()!;
    final radius = BorderRadius.circular(size / 4);
    final letter = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.ownBubble, borderRadius: radius),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: colors.onOwnBubble,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.45,
        ),
      ),
    );
    final path = avatar;
    if (path == null) return letter;

    // While loading, or if the picture fails, the letter is shown instead.
    final bytes = ref.watch(avatarBytesProvider(path)).value;
    if (bytes == null) return letter;
    return ClipRRect(
      borderRadius: radius,
      child: Image.memory(
        bytes,
        key: const Key('avatar-image'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => letter,
      ),
    );
  }
}

/// The avatar of the user with [userId], looked up in the member list (so it updates
/// live when they change it). [fallbackName] is used while the list is loading.
class MemberAvatar extends ConsumerWidget {
  const MemberAvatar({
    super.key,
    required this.userId,
    required this.fallbackName,
    this.size = 34,
  });

  final int? userId;
  final String fallbackName;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = userId == null ? null : ref.watch(membersByIdProvider)[userId];
    return UserAvatar(
      name: m?.displayName ?? fallbackName,
      avatar: m?.avatar,
      size: size,
    );
  }
}
