import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_config.dart';
import '../../app_config/app_theme.dart';
import '../../core/certificate_trust.dart';
import '../../core/server_address.dart';
import '../../core/server_info.dart';
import '../../core/session_controller.dart';
import '../../widgets/centered_form.dart';
import '../../widgets/release_badge.dart';
import '../../widgets/about.dart';
import 'certificate_dialog.dart';

/// First screen: the user enters a server address and the app checks it via GET /api/v1/info.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _addressController = TextEditingController(
    text: AppConfig.defaultServerAddress,
  );

  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      final server = parseServerAddress(_addressController.text);
      final info = await _fetchInfoAskingTrust(server);
      if (info != null) {
        // Success: the app switches to the login screen by itself (the state changed).
        await ref.read(sessionProvider.notifier).useServer(server, info);
        return;
      }
      _error = 'Not connected: the certificate was not trusted.';
    } on FormatException catch (e) {
      _error = e.message;
    } on ConnectException catch (e) {
      _error = e.message;
    }

    if (!mounted) return; // the screen was closed while we were waiting
    setState(() => _connecting = false);
  }

  /// Fetches /info. If the server's certificate is self-signed (or changed), asks the user
  /// to verify its fingerprint first; returns null if they decline.
  Future<ServerInfo?> _fetchInfoAskingTrust(Uri server) async {
    final trust = ref.read(certificateTrustProvider);
    try {
      return await fetchServerInfo(
        server,
        client: ref.read(httpClientProvider),
        trust: trust,
      );
    } on UntrustedCertificateException catch (e) {
      if (!mounted || !await confirmCertificate(context, e)) return null;
      await ref
          .read(sessionProvider.notifier)
          .trustCertificate(server, e.fingerprint);
      // Try again: the certificate is now pinned and accepted.
      return fetchServerInfo(
        server,
        client: ref.read(httpClientProvider),
        trust: trust,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
          'Enter the address of the server you want to join.',
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.large),
        TextField(
          key: const Key('server-address'),
          controller: _addressController,
          autofocus: true,
          enabled: !_connecting,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'chat.example.com or 192.168.1.10:8080',
          ),
          onSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: AppSpacing.medium),
        FilledButton(
          onPressed: _connecting ? null : _connect,
          child: _connecting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
        ),
        if (_error case final error?) ...[
          const SizedBox(height: AppSpacing.large),
          ErrorText(error),
        ],
        const SizedBox(height: AppSpacing.large),
        TextButton(
          key: const Key('about'),
          onPressed: () => showAbout(context),
          child: const Text('About & licenses'),
        ),
      ],
    );
  }
}
