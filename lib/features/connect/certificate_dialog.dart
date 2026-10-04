import 'package:flutter/material.dart';

import '../../app_config/app_theme.dart';
import '../../core/certificate_trust.dart';

/// Asks the user to verify a self-signed certificate (trust on first use).
/// Returns true if the user chose to trust it.
///
/// For a CHANGED certificate the dialog is a warning, and trusting needs an extra,
/// deliberate step (ticking a box), because this is what an attack would look like.
Future<bool> confirmCertificate(
  BuildContext context,
  UntrustedCertificateException e,
) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CertificateDialog(e),
  );
  return ok ?? false;
}

class _CertificateDialog extends StatefulWidget {
  const _CertificateDialog(this.e);
  final UntrustedCertificateException e;

  @override
  State<_CertificateDialog> createState() => _CertificateDialogState();
}

class _CertificateDialogState extends State<_CertificateDialog> {
  bool _confirmedChange = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.e;
    final host = '${e.server.host}:${e.server.port}';
    final fingerprintBox = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.medium),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        // Split into 4 lines of 8 pairs: much easier to compare by eye.
        _grouped(e.fingerprint),
        key: const Key('fingerprint'),
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          height: 1.5,
        ),
      ),
    );

    if (!e.changed) {
      return AlertDialog(
        title: const Text('Verify this server'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$host uses its own (self-signed) certificate. The connection is encrypted, '
                'but the app cannot check automatically that it really is your server.',
              ),
              const SizedBox(height: AppSpacing.medium),
              const Text(
                'Compare this fingerprint with the one the server owner gave you:',
              ),
              const SizedBox(height: AppSpacing.small),
              fingerprintBox,
              const SizedBox(height: AppSpacing.small),
              Text(
                'Only continue if they match exactly. The app remembers it and will warn you if it ever changes.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('trust-certificate'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('They match: trust'),
          ),
        ],
      );
    }

    return AlertDialog(
      icon: Icon(Icons.gpp_bad, color: theme.colorScheme.error, size: 40),
      title: Text(
        'Certificate changed!',
        style: TextStyle(color: theme.colorScheme.error),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'The certificate of $host is NOT the one you trusted before. Someone may be '
              'intercepting your connection (a "man-in-the-middle" attack), or the server owner '
              'replaced the certificate.',
            ),
            const SizedBox(height: AppSpacing.medium),
            const Text('New fingerprint:'),
            const SizedBox(height: AppSpacing.small),
            fingerprintBox,
            const SizedBox(height: AppSpacing.small),
            CheckboxListTile(
              key: const Key('confirm-change'),
              contentPadding: EdgeInsets.zero,
              value: _confirmedChange,
              onChanged: (v) => setState(() => _confirmedChange = v ?? false),
              title: const Text(
                'The server owner confirmed this new fingerprint to me',
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const Key('reject-certificate'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel (safe)'),
        ),
        TextButton(
          key: const Key('trust-certificate'),
          onPressed: _confirmedChange
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('Trust the new certificate'),
        ),
      ],
    );
  }
}

/// "AA:BB:...:FF" (32 pairs) -> 4 lines of 8 pairs.
String _grouped(String fingerprint) {
  final pairs = fingerprint.split(':');
  return [
    for (var i = 0; i < pairs.length; i += 8) pairs.skip(i).take(8).join(':'),
  ].join('\n');
}
