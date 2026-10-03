import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_config.dart';
import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/session_controller.dart';
import '../../widgets/centered_form.dart';

/// Placeholder main screen for M1: who you are, logout, and (for the owner) invites.
/// Channels and chat replace most of this in M2.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.session});

  final LoggedIn session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = session.user;
    final controller = ref.read(sessionProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${AppConfig.appName} · ${session.info.name}',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton.icon(
            key: const Key('logout'),
            onPressed: controller.logout,
            icon: const Icon(Icons.logout),
            label: const Text('Log out'),
          ),
          const SizedBox(width: AppSpacing.small),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.large),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Welcome, ${user.displayName}!',
                  key: const Key('welcome'),
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.small),
                Text(
                  '@${user.username}${user.isOwner ? ' · server owner' : ''}',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.large),
                // The server enforces this too; hiding the button only keeps the UI tidy.
                if (user.isOwner) const _InviteCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lets the owner create an invite code and copy it.
class _InviteCard extends ConsumerStatefulWidget {
  const _InviteCard();

  @override
  ConsumerState<_InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<_InviteCard> {
  bool _busy = false;
  CreatedInvite? _created;
  String? _error;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final controller = ref.read(sessionProvider.notifier);
    try {
      final created = await controller.authorizedApi().createInvite();
      if (!mounted) return;
      setState(() {
        _created = created;
        _busy = false;
      });
      return;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await controller.sessionExpired(); // goes back to the login screen
        return;
      }
      _error = e.message;
    } on NetworkException catch (e) {
      _error = e.message;
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Invite code copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = _created;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Invite a friend', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.small),
            const Text('Creates a code for one person, valid for 7 days.'),
            const SizedBox(height: AppSpacing.medium),
            FilledButton.tonal(
              key: const Key('create-invite'),
              onPressed: _busy ? null : _create,
              child: const Text('Create invite code'),
            ),
            if (created != null) ...[
              const SizedBox(height: AppSpacing.medium),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      created.code,
                      key: const Key('invite-code'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    onPressed: () => _copy(created.code),
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
              Text(
                'Save it now: it is shown only once.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: AppSpacing.medium),
              ErrorText(error),
            ],
          ],
        ),
      ),
    );
  }
}
