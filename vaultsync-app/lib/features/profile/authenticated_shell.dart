import 'package:flutter/material.dart';

import '../../core/storage/app_storage.dart';
import '../../core/theme/app_theme.dart';
import '../auth/auth_service.dart';
import '../sync/upload_key_store.dart';
import 'app_permission_gateway.dart';
import 'avatar_store.dart';
import 'profile_screen.dart';

class AuthenticatedShell extends StatefulWidget {
  final Widget syncHome;
  final SessionStore storage;
  final UserProfileGateway profileGateway;
  final AppReleaseGateway? releaseGateway;
  final AvatarStore avatarStore;
  final AvatarGateway? avatarGateway;
  final UploadKeyStore? avatarKeys;
  final AppPermissionGateway? permissionGateway;
  final String platform;
  final String serverAddress;
  final Future<void> Function()? onConfigureServer;
  final Future<void> Function()? onSignOut;
  final VaultThemePreset selectedTheme;
  final Future<void> Function(VaultThemePreset theme)? onThemeChanged;

  const AuthenticatedShell({
    super.key,
    required this.syncHome,
    required this.storage,
    required this.profileGateway,
    this.releaseGateway,
    this.avatarStore = const LocalAvatarStore(),
    this.avatarGateway,
    this.avatarKeys,
    this.permissionGateway,
    required this.platform,
    required this.serverAddress,
    this.onConfigureServer,
    this.onSignOut,
    this.selectedTheme = VaultThemePreset.celadon,
    this.onThemeChanged,
  });

  @override
  State<AuthenticatedShell> createState() => _AuthenticatedShellState();
}

class _AuthenticatedShellState extends State<AuthenticatedShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          widget.syncHome,
          ProfileScreen(
            storage: widget.storage,
            profileGateway: widget.profileGateway,
            releaseGateway: widget.releaseGateway,
            avatarStore: widget.avatarStore,
            avatarGateway: widget.avatarGateway,
            avatarKeys: widget.avatarKeys,
            permissionGateway: widget.permissionGateway,
            platform: widget.platform,
            serverAddress: widget.serverAddress,
            onConfigureServer: widget.onConfigureServer,
            onSignOut: widget.onSignOut,
            selectedTheme: widget.selectedTheme,
            onThemeChanged: widget.onThemeChanged,
            active: _selectedIndex == 1,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
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
