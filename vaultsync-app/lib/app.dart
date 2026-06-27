import 'package:flutter/material.dart';

import 'core/config/app_config.dart';
import 'features/auth/login_screen.dart';

class VaultSyncApp extends StatelessWidget {
  const VaultSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VaultSync',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}
