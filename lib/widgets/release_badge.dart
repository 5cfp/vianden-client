import 'package:flutter/material.dart';

import '../app_config/app_config.dart';
import '../app_config/app_theme.dart';

/// "ALPHA · v0.1.0-alpha" for pre-release builds. Shows nothing for normal releases.
///
/// [withNotice]: also show the one-line explanation under the badge (connect and login
/// screens). Without it, the explanation appears when hovering (chat screen).
class ReleaseBadge extends StatelessWidget {
  const ReleaseBadge({super.key, this.withNotice = false});

  final bool withNotice;

  @override
  Widget build(BuildContext context) {
    final stage = AppConfig.releaseStage;
    if (stage == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    final badge = Container(
      key: const Key('release-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.primary),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$stage · v${AppConfig.appVersion}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );

    if (!withNotice) {
      return Tooltip(message: AppConfig.preReleaseNotice, child: badge);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        badge,
        const SizedBox(height: AppSpacing.small),
        Text(
          AppConfig.preReleaseNotice,
          key: const Key('release-notice'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.muted),
        ),
      ],
    );
  }
}
