import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/session_controller.dart';
import '../../widgets/centered_form.dart';

/// Shown at startup when the saved server cannot be reached or is incompatible.
/// The saved login is kept, so "Try again" can continue where the user left off.
class ServerProblemScreen extends ConsumerWidget {
  const ServerProblemScreen({super.key, required this.problem});

  final ServerProblem problem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(sessionProvider.notifier);

    return CenteredForm(
      children: [
        Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.error),
        const SizedBox(height: AppSpacing.medium),
        Text(
          'Cannot connect to ${problem.server.host}',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.small),
        ErrorText(problem.message),
        const SizedBox(height: AppSpacing.large),
        FilledButton(
          key: const Key('retry'),
          onPressed: controller.retry,
          child: const Text('Try again'),
        ),
        const SizedBox(height: AppSpacing.small),
        TextButton(
          onPressed: controller.changeServer,
          child: const Text('Use a different server'),
        ),
      ],
    );
  }
}
