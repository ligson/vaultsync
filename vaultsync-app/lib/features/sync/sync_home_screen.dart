import 'package:flutter/material.dart';

class SyncHomeScreen extends StatelessWidget {
  const SyncHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('同步主页')),
      body: const Center(
        child: Text('VaultSync MVP'),
      ),
    );
  }
}
