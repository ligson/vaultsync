import 'package:flutter/material.dart';

import '../../core/storage/app_storage.dart';
import '../auth/auth_service.dart';
import 'app_permission_gateway.dart';
import 'avatar_store.dart';
import 'profile_screen.dart';

class AuthenticatedShell extends StatefulWidget {
  final Widget syncHome;
  final SessionStore storage;
  final UserProfileGateway profileGateway;
  final AppReleaseGateway? releaseGateway;
  final AvatarStore avatarStore;
  final AppPermissionGateway? permissionGateway;
  final String platform;
  final String serverAddress;
  final Future<void> Function()? onConfigureServer;
  final Future<void> Function()? onSignOut;

  const AuthenticatedShell({
    super.key,
    required this.syncHome,
    required this.storage,
    required this.profileGateway,
    this.releaseGateway,
    this.avatarStore = const LocalAvatarStore(),
    this.permissionGateway,
    required this.platform,
    required this.serverAddress,
    this.onConfigureServer,
    this.onSignOut,
  });

  @override
  State<AuthenticatedShell> createState() => _AuthenticatedShellState();
}

class _AuthenticatedShellState extends State<AuthenticatedShell> {
  int _selectedIndex = 0;
  bool _profileOpened = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          widget.syncHome,
          if (_profileOpened)
            ProfileScreen(
              storage: widget.storage,
              profileGateway: widget.profileGateway,
              releaseGateway: widget.releaseGateway,
              avatarStore: widget.avatarStore,
              permissionGateway: widget.permissionGateway,
              platform: widget.platform,
              serverAddress: widget.serverAddress,
              onConfigureServer: widget.onConfigureServer,
              onSignOut: widget.onSignOut,
            )
          else
            const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
            _profileOpened = _profileOpened || index == 1;
          });
        },
        destinations: const [
          NavigationDestination(
            key: ValueKey('sync_navigation_destination'),
            icon: Icon(Icons.sync_outlined),
            selectedIcon: Icon(Icons.sync),
            label: '同步',
          ),
          NavigationDestination(
            key: ValueKey('profile_navigation_destination'),
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
