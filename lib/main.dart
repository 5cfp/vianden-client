import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_config/app_config.dart';
import 'app_config/app_theme.dart';
import 'core/session_controller.dart';
import 'features/auth/auth_screen.dart';
import 'features/chat/chat_screen.dart';
import 'features/connect/connect_screen.dart';
import 'features/connect/server_problem_screen.dart';

void main() {
  // ProviderScope holds the state of all Riverpod providers for the whole app.
  runApp(const ProviderScope(child: ViandenApp()));
}

class ViandenApp extends StatelessWidget {
  const ViandenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      theme: AppTheme.light(),
      debugShowCheckedModeBanner: false,
      home: const AppRoot(),
    );
  }
}

/// Picks the screen from the current [AppState]. When the state changes
/// (connect, login, logout...), this rebuilds and shows the right screen.
class AppRoot extends ConsumerWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionProvider);

    return switch (state) {
      AsyncData(value: final app) => switch (app) {
        NeedsServer() => const ConnectScreen(),
        LoggedOut(:final info) => AuthScreen(serverName: info.name),
        LoggedIn() => ChatScreen(session: app),
        ServerProblem() => ServerProblemScreen(problem: app),
      },
      AsyncError(:final error) => Scaffold(
        body: Center(child: Text('Could not start: $error')),
      ),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}
