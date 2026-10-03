import 'package:flutter/material.dart';

import 'app_config/app_config.dart';
import 'app_config/app_theme.dart';
import 'features/connect/connect_screen.dart';

void main() {
  runApp(const ViandenApp());
}

class ViandenApp extends StatelessWidget {
  const ViandenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      theme: AppTheme.light(),
      debugShowCheckedModeBanner: false,
      home: const ConnectScreen(),
    );
  }
}
