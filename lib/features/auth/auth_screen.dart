import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_config.dart';
import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/session_controller.dart';
import '../../widgets/centered_form.dart';
import '../../widgets/release_badge.dart';

enum _Mode { login, register }

/// Login and registration on one screen, switched with a toggle.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, required this.serverName});

  /// Name from the server's /info: shows the user WHICH server they are logging in to.
  final String serverName;

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _inviteCode = TextEditingController();

  _Mode _mode = _Mode.login;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_username, _displayName, _password, _inviteCode]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final session = ref.read(sessionProvider.notifier);
    try {
      if (_mode == _Mode.login) {
        await session.login(_username.text, _password.text);
      } else {
        await session.register(
          username: _username.text,
          displayName: _displayName.text,
          password: _password.text,
          inviteCode: _inviteCode.text.trim(),
        );
      }
      return; // success: the app switches to the home screen by itself
    } on ApiException catch (e) {
      _error = e.message;
    } on NetworkException catch (e) {
      _error = e.message;
    }

    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final registering = _mode == _Mode.register;

    return CenteredForm(
      children: [
        Text(
          AppConfig.appName,
          style: theme.textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.small),
        const ReleaseBadge(withNotice: true),
        const SizedBox(height: AppSpacing.small),
        Text(
          widget.serverName,
          key: const Key('server-name'),
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.large),
        SegmentedButton<_Mode>(
          segments: const [
            ButtonSegment(value: _Mode.login, label: Text('Log in')),
            ButtonSegment(value: _Mode.register, label: Text('Register')),
          ],
          selected: {_mode},
          onSelectionChanged: _busy
              ? null
              : (s) => setState(() {
                  _mode = s.first;
                  _error = null;
                }),
        ),
        const SizedBox(height: AppSpacing.large),
        TextField(
          key: const Key('username'),
          controller: _username,
          enabled: !_busy,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Username'),
          textInputAction: TextInputAction.next,
        ),
        if (registering) ...[
          const SizedBox(height: AppSpacing.medium),
          TextField(
            key: const Key('display-name'),
            controller: _displayName,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Display name (optional)',
              helperText: 'How others see you. Defaults to your username.',
            ),
            textInputAction: TextInputAction.next,
          ),
        ],
        const SizedBox(height: AppSpacing.medium),
        TextField(
          key: const Key('password'),
          controller: _password,
          enabled: !_busy,
          obscureText: true, // shows dots instead of the password
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: registering ? 'At least 8 characters.' : null,
          ),
          onSubmitted: registering ? null : (_) => _submit(),
        ),
        if (registering) ...[
          const SizedBox(height: AppSpacing.medium),
          TextField(
            key: const Key('invite-code'),
            controller: _inviteCode,
            enabled: !_busy,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Invite code',
              helperText: 'From the server owner (or the setup token if you run the server).',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
        const SizedBox(height: AppSpacing.large),
        FilledButton(
          key: const Key('submit'),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(registering ? 'Create account' : 'Log in'),
        ),
        if (_error case final error?) ...[
          const SizedBox(height: AppSpacing.medium),
          ErrorText(error),
        ],
        const SizedBox(height: AppSpacing.large),
        TextButton(
          onPressed: _busy
              ? null
              : () => ref.read(sessionProvider.notifier).changeServer(),
          child: const Text('Use a different server'),
        ),
      ],
    );
  }
}
