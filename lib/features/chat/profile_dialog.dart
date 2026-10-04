import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/session_controller.dart';
import '../../widgets/centered_form.dart';
import '../../widgets/user_avatar.dart';

/// Change your display name and avatar.
Future<void> showProfileDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ProfileDialog());

class _ProfileDialog extends ConsumerStatefulWidget {
  const _ProfileDialog();

  @override
  ConsumerState<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends ConsumerState<_ProfileDialog> {
  late final _name = TextEditingController(text: _me?.displayName ?? '');
  bool _busy = false;
  String? _error;

  static const maxAvatarBytes = 5 * 1024 * 1024; // same limit as the server

  User? get _me => switch (ref.read(sessionProvider).value) {
    LoggedIn(:final user) => user,
    _ => null,
  };

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Runs an API call that returns our updated user, and shows it (or the error).
  Future<void> _run(Future<User> Function(ApiClient api) call) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final session = ref.read(sessionProvider.notifier);
    try {
      session.setUser(await call(session.authorizedApi()));
    } on ApiException catch (e) {
      _error = e.message;
    } on NetworkException catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickAvatar() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > maxAvatarBytes) {
      setState(() => _error = 'The picture is larger than 5 MB.');
      return;
    }
    final bytes = await file.readAsBytes();
    await _run((api) => api.setAvatar(bytes));
  }

  Future<void> _saveName() async {
    await _run((api) => api.updateProfile(_name.text));
    if (mounted && _error == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Watch the session so a new avatar shows here at once.
    final me = switch (ref.watch(sessionProvider).value) {
      LoggedIn(:final user) => user,
      _ => null,
    };
    if (me == null) return const SizedBox.shrink();

    return AlertDialog(
      title: const Text('Your profile'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                UserAvatar(name: me.displayName, avatar: me.avatar, size: 64),
                const SizedBox(width: AppSpacing.medium),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      OutlinedButton(
                        key: const Key('change-avatar'),
                        onPressed: _busy ? null : _pickAvatar,
                        child: const Text('Change picture'),
                      ),
                      if (me.avatar != null)
                        TextButton(
                          key: const Key('remove-avatar'),
                          onPressed: _busy
                              ? null
                              : () => _run((api) => api.removeAvatar()),
                          child: const Text('Remove'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.medium),
            TextField(
              key: const Key('profile-name'),
              controller: _name,
              enabled: !_busy,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Display name'),
              onSubmitted: (_) => _saveName(),
            ),
            Text(
              '@${me.username} · your login name cannot be changed',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).extension<ChatColors>()!.muted,
              ),
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
          child: const Text('Close'),
        ),
        FilledButton(
          key: const Key('profile-save'),
          onPressed: _busy ? null : _saveName,
          child: const Text('Save name'),
        ),
      ],
    );
  }
}
