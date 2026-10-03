import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../app_config/app_config.dart';
import '../../app_config/app_theme.dart';
import '../../core/server_address.dart';
import '../../core/server_info.dart';

/// First screen: the user enters a server address and the app checks it via GET /api/v1/info.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.httpClient});

  /// Tests pass a fake client; the real app uses a normal one.
  final http.Client? httpClient;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _addressController = TextEditingController(
    text: AppConfig.defaultServerAddress,
  );
  late final http.Client _client = widget.httpClient ?? http.Client();

  bool _connecting = false;
  ServerInfo? _connectedTo;
  String? _error;

  @override
  void dispose() {
    _addressController.dispose();
    // Only close the client we created; a client passed in belongs to the caller.
    if (widget.httpClient == null) {
      _client.close();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _connectedTo = null;
      _error = null;
    });

    ServerInfo? info;
    String? error;
    try {
      final server = parseServerAddress(_addressController.text);
      info = await fetchServerInfo(server, client: _client);
    } on FormatException catch (e) {
      error = e.message;
    } on ConnectException catch (e) {
      error = e.message;
    }

    if (!mounted) return; // the screen was closed while we were waiting
    setState(() {
      _connecting = false;
      _connectedTo = info;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.large),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  AppConfig.appName,
                  style: theme.textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
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
                const SizedBox(height: AppSpacing.large),
                if (_error case final error?)
                  Text(
                    error,
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                if (_connectedTo case final info?) _ConnectedCard(info: info),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({required this.info});

  final ServerInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.check_circle, color: theme.colorScheme.primary),
        // The name comes from the server, so it is untrusted text. Text widgets never
        // interpret it (no HTML/markup), and long names are cut off instead of breaking the layout.
        title: Text(
          'Connected to ${info.name}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'Server version ${info.version} · protocol ${info.protocolVersion}',
        ),
      ),
    );
  }
}
