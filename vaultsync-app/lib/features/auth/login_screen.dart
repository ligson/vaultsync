import 'package:flutter/material.dart';

import '../sync/sync_home_screen.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VaultSync')),
      body: Center(
        child: FilledButton(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SyncHomeScreen(),
              ),
            );
          },
          child: const Text('进入同步主页'),
        ),
      ),
    );
  }
}
