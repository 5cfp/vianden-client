import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import '../../widgets/centered_form.dart';
import '../../widgets/user_avatar.dart';
import 'chat_providers.dart';

/// The member list: everyone sees names and roles. Moderators and up also get
/// actions (change role, kick, ban) for members BELOW their own role. Hiding the
/// buttons is only for a clean UI: the server checks every action again.
Future<void> showMembersDialog(BuildContext context, User me) {
  return showDialog<void>(
    context: context,
    builder: (_) => _MembersDialog(me: me),
  );
}

class _MembersDialog extends ConsumerWidget {
  const _MembersDialog({required this.me});

  final User me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider);
    return AlertDialog(
      title: const Text('Members'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: switch (members) {
          AsyncData(:final value) => ListView(
            children: [
              for (final m in _sorted(value)) _MemberTile(member: m, me: me),
            ],
          ),
          AsyncError(:final error) => Center(child: ErrorText('$error')),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  /// Highest role first, then by name.
  static List<Member> _sorted(List<Member> list) => [...list]
    ..sort((a, b) {
      final byRole = b.role.index.compareTo(a.role.index);
      return byRole != 0
          ? byRole
          : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.member, required this.me});

  final Member member;
  final User me;

  /// Same rule as the server (perm.CanActOn): the permission AND a higher role.
  bool _canAct(String permission) =>
      me.can(permission) && me.role.above(member.role);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final banned = member.banned ?? false;
    final canRole = _canAct(Permission.manageRoles);
    final canKick = _canAct(Permission.kickMembers);
    final canBan = _canAct(Permission.banMembers);

    final subtitle = [
      '@${member.username}',
      member.role.label,
      if (banned) 'banned',
    ].join(' · ');

    return ListTile(
      key: Key('member-${member.id}'),
      contentPadding: EdgeInsets.zero,
      leading: UserAvatar(
        name: member.displayName,
        avatar: member.avatar,
        size: 32,
      ),
      title: Text(
        member.displayName,
        style: banned
            ? TextStyle(
                color: colors.muted,
                decoration: TextDecoration.lineThrough,
              )
            : null,
      ),
      subtitle: Tooltip(
        message: banned ? 'Reason: ${member.banReason ?? ''}' : '',
        child: Text(subtitle, style: TextStyle(color: colors.muted)),
      ),
      trailing: !(canRole || canKick || canBan)
          ? null
          : PopupMenuButton<String>(
              key: Key('member-menu-${member.id}'),
              tooltip: 'Actions',
              onSelected: (choice) => _run(context, ref, choice),
              itemBuilder: (_) => [
                if (canRole)
                  const PopupMenuItem(
                    value: 'role',
                    child: Text('Change role'),
                  ),
                if (canKick)
                  const PopupMenuItem(
                    value: 'kick',
                    child: Text('Kick (sign out everywhere)'),
                  ),
                if (canBan && !banned)
                  const PopupMenuItem(value: 'ban', child: Text('Ban')),
                if (canBan && banned)
                  const PopupMenuItem(value: 'unban', child: Text('Unban')),
              ],
            ),
    );
  }

  Future<void> _run(BuildContext context, WidgetRef ref, String choice) async {
    final members = ref.read(membersProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    void show(String text) =>
        messenger.showSnackBar(SnackBar(content: Text(text)));
    try {
      switch (choice) {
        case 'role':
          final role = await _pickRole(context);
          if (role != null && role != member.role) {
            await members.setRole(member.id, role);
          }
        case 'kick':
          if (await _confirm(
            context,
            'Kick ${member.displayName}?',
            'They are signed out on all devices. They can log in again.',
            'Kick',
          )) {
            await members.kick(member.id);
            show('${member.displayName} was signed out.');
          }
        case 'ban':
          final reason = await _askBanReason(context);
          if (reason != null) await members.ban(member.id, reason);
        case 'unban':
          await members.unban(member.id);
      }
    } on ApiException catch (e) {
      show(e.message);
    } on NetworkException catch (e) {
      show(e.message);
    }
  }

  /// Roles you can give: only those below your own (never owner).
  Future<Role?> _pickRole(BuildContext context) {
    var picked = member.role;
    final choices = [
      for (final r in Role.values)
        if (me.role.above(r)) r,
    ];
    return showDialog<Role>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Role of ${member.displayName}'),
        content: SizedBox(
          width: 320,
          child: DropdownButtonFormField<Role>(
            key: const Key('member-role'),
            initialValue: picked,
            decoration: const InputDecoration(labelText: 'Role'),
            items: [
              for (final r in choices)
                DropdownMenuItem(value: r, child: Text(r.label)),
            ],
            onChanged: (r) => picked = r ?? picked,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('member-role-save'),
            onPressed: () => Navigator.of(context).pop(picked),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Returns the reason (may be empty), or null if cancelled.
  Future<String?> _askBanReason(BuildContext context) => showDialog<String>(
    context: context,
    builder: (_) => _BanDialog(name: member.displayName),
  );

  Future<bool> _confirm(
    BuildContext context,
    String title,
    String body,
    String action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-action'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

/// Asks for a ban reason. A StatefulWidget so the text controller lives exactly as
/// long as the dialog (disposing it earlier breaks the closing animation).
class _BanDialog extends StatefulWidget {
  const _BanDialog({required this.name});

  final String name;

  @override
  State<_BanDialog> createState() => _BanDialogState();
}

class _BanDialogState extends State<_BanDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Ban ${widget.name}?'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'They are signed out and cannot log in until unbanned. '
              'Their messages stay.',
            ),
            const SizedBox(height: AppSpacing.small),
            TextField(
              key: const Key('ban-reason'),
              controller: _reason,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Reason (optional, they will see it)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-ban'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(_reason.text),
          child: const Text('Ban'),
        ),
      ],
    );
  }
}
