import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import '../../widgets/centered_form.dart';

/// What the room dialog returns.
typedef RoomSettings = ({
  String name,
  String topic,
  Role viewRole,
  Role sendRole,
});

/// Asks for a room's name, topic, and who may see / write in it (create or edit).
/// [save] does the API call; its errors are shown inside the dialog, which stays
/// open so the user can fix the input. [myRole] limits the access choices: you
/// cannot lock a room above your own role (the server refuses that too).
Future<void> showRoomDialog(
  BuildContext context, {
  required String title,
  required String actionLabel,
  required Role myRole,
  Channel? initial,
  required Future<void> Function(RoomSettings settings) save,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RoomDialog(
      title: title,
      actionLabel: actionLabel,
      myRole: myRole,
      initial: initial,
      save: save,
    ),
  );
}

class _RoomDialog extends StatefulWidget {
  const _RoomDialog({
    required this.title,
    required this.actionLabel,
    required this.myRole,
    required this.initial,
    required this.save,
  });

  final String title;
  final String actionLabel;
  final Role myRole;
  final Channel? initial;
  final Future<void> Function(RoomSettings settings) save;

  @override
  State<_RoomDialog> createState() => _RoomDialogState();
}

class _RoomDialogState extends State<_RoomDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _topic = TextEditingController(text: widget.initial?.topic ?? '');
  late Role _viewRole = widget.initial?.viewRole ?? Role.member;
  late Role _sendRole = widget.initial?.sendRole ?? Role.member;
  bool _busy = false;
  String? _error;

  /// The roles this user may choose: their own and below.
  List<Role> get _choices => [
    for (final r in Role.values)
      if (widget.myRole.atLeast(r)) r,
  ];

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.save((
        name: _name.text,
        topic: _topic.text,
        viewRole: _viewRole,
        sendRole: _sendRole,
      ));
      if (mounted) Navigator.of(context).pop();
      return;
    } on ApiException catch (e) {
      _error = e.message;
    } on NetworkException catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('room-name'),
              controller: _name,
              autofocus: true,
              enabled: !_busy,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Room name'),
            ),
            const SizedBox(height: AppSpacing.small),
            TextField(
              key: const Key('room-topic'),
              controller: _topic,
              enabled: !_busy,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Topic (optional)'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppSpacing.small),
            RoleDropdown(
              key: const Key('room-view-role'),
              label: 'Who can see it',
              value: _viewRole,
              choices: _choices,
              enabled: !_busy,
              onChanged: (r) => setState(() {
                _viewRole = r;
                // You cannot write where you cannot read: raise "write" along with "see".
                if (!_sendRole.atLeast(r)) _sendRole = r;
              }),
            ),
            const SizedBox(height: AppSpacing.medium),
            RoleDropdown(
              key: const Key('room-send-role'),
              label: 'Who can write',
              value: _sendRole,
              choices: [
                for (final r in _choices)
                  if (r.atLeast(_viewRole)) r,
              ],
              enabled: !_busy,
              onChanged: (r) => setState(() => _sendRole = r),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: AppSpacing.small),
              ErrorText(error),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('room-save'),
          onPressed: _busy ? null : _submit,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

/// Asks before deleting a room, because its messages are deleted too.
Future<bool> confirmDeleteRoom(BuildContext context, Channel room) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete "${room.name}"?'),
      content: const Text(
        'All messages in this room will be deleted for everyone. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-delete'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete room'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Creates an invite (via [create]) and shows its code once, with a copy button.
Future<void> showInviteDialog(
  BuildContext context,
  Future<CreatedInvite> Function() create,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _InviteDialog(create: create),
  );
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.create});
  final Future<CreatedInvite> Function() create;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  late final Future<CreatedInvite> _invite = widget.create();
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Invite a friend'),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<CreatedInvite>(
          future: _invite,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return ErrorText(snapshot.error.toString());
            }
            final invite = snapshot.data;
            if (invite == null) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Send this code to one friend. They choose Register and paste it as the invite code. It works once, for 7 days.',
                ),
                const SizedBox(height: AppSpacing.medium),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.medium),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    invite.code,
                    key: const Key('invite-code'),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.small),
                Text(
                  'Save it now: it is shown only once.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.medium),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: invite.code));
                    if (mounted) setState(() => _copied = true);
                  },
                  icon: Icon(_copied ? Icons.check : Icons.copy),
                  label: Text(_copied ? 'Copied' : 'Copy code'),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// A dropdown to pick a role, limited to [choices].
class RoleDropdown extends StatelessWidget {
  const RoleDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final Role value;
  final List<Role> choices;
  final ValueChanged<Role> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<Role>(
      // The key makes the field show [value] again when the parent changes it.
      key: ValueKey(value),
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final r in choices)
          DropdownMenuItem(
            value: r,
            child: Text(switch (r) {
              Role.member => 'Everyone',
              Role.owner => 'Owner only',
              _ => '${r.label}s and up',
            }),
          ),
      ],
      onChanged: enabled ? (r) => r == null ? null : onChanged(r) : null,
    );
  }
}

/// Asks before a moderator deletes someone else's message.
Future<bool> confirmDeleteMessage(BuildContext context, Message message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete this message?'),
      content: Text(
        'It is removed for everyone. Others see "Message deleted" in its place.\n\n'
        '"${message.content.length > 200 ? '${message.content.substring(0, 200)}…' : message.content}"',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-delete-message'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
