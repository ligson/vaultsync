import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/core/theme/app_theme.dart';
import 'package:vaultsync_app/features/auth/auth_models.dart';
import 'package:vaultsync_app/features/auth/auth_service.dart';
import 'package:vaultsync_app/features/device/device_models.dart';
import 'package:vaultsync_app/features/profile/authenticated_shell.dart';
import 'package:vaultsync_app/features/profile/app_permission_gateway.dart';
import 'package:vaultsync_app/features/profile/avatar_store.dart';
import 'package:vaultsync_app/features/profile/profile_screen.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'VaultSync',
      packageName: 'com.ligson.vaultsync',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('authenticated shell adds sync and profile navigation', (
    tester,
  ) async {
    final gateway = FakeProfileGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticatedShell(
          syncHome: const Scaffold(body: Text('同步工作区')),
          storage: FakeSessionStore(),
          profileGateway: gateway,
          avatarStore: MemoryAvatarStore(),
          platform: 'android',
          serverAddress: 'https://files.example.com',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('同步工作区'), findsOneWidget);
    expect(find.text('同步'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(gateway.loadCount, 0);

    await tester.tap(
      find.byKey(const ValueKey('profile_navigation_destination')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile_settings_list')), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(gateway.loadCount, 1);

    await tester.tap(find.byKey(const ValueKey('sync_navigation_destination')));
    await tester.pumpAndSettle();
    expect(find.text('同步工作区'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('profile_navigation_destination')),
    );
    await tester.pumpAndSettle();
    expect(gateway.loadCount, 1);
  });

  testWidgets('profile shows stable skeleton while first request is pending', (
    tester,
  ) async {
    final completer = Completer<UserProfile>();
    final gateway = FakeProfileGateway(profileLoader: () => completer.future);
    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticatedShell(
          syncHome: const Scaffold(body: Text('同步工作区')),
          storage: FakeSessionStore(),
          profileGateway: gateway,
          avatarStore: MemoryAvatarStore(),
          platform: 'macos',
          serverAddress: 'https://files.example.com',
        ),
      ),
    );
    await tester.pump();

    expect(gateway.loadCount, 0);
    await tester.tap(
      find.byKey(const ValueKey('profile_navigation_destination')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('profile_loading_skeleton')),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(gateway.loadCount, 1);

    completer.complete(gateway.profile);
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('profile theme settings exposes Chinese presets', (tester) async {
    VaultThemePreset? selected;
    await tester.pumpWidget(
      _profileApp(
        gateway: FakeProfileGateway(),
        selectedTheme: VaultThemePreset.celadon,
        onThemeChanged: (theme) async => selected = theme,
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('theme_settings_tile')),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.drag(
      find.byKey(const ValueKey('profile_settings_list')),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme_settings_tile')));
    await tester.pumpAndSettle();

    expect(find.text('青瓷'), findsOneWidget);
    expect(find.text('朱砂'), findsOneWidget);
    expect(find.text('墨竹'), findsOneWidget);
    expect(find.text('黛蓝'), findsOneWidget);
    expect(find.text('松烟'), findsOneWidget);
    expect(find.text('夜朱'), findsOneWidget);
    expect(find.text('乌金'), findsOneWidget);
    expect(find.text('深黛'), findsOneWidget);
    expect(find.text('松烟'), findsOneWidget);
    expect(find.text('夜朱'), findsOneWidget);
    expect(find.text('乌金'), findsOneWidget);
    expect(find.text('深黛'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('theme_option_cinnabar')));
    await tester.pumpAndSettle();
    expect(selected, VaultThemePreset.cinnabar);
  });

  testWidgets('profile shows storage and updates personal details', (
    tester,
  ) async {
    final gateway = FakeProfileGateway();
    await tester.pumpWidget(_profileApp(gateway: gateway));
    await tester.pumpAndSettle();

    expect(find.text('已使用 2.0 GB，共 10.0 GB'), findsOneWidget);
    expect(find.text('alice@example.com'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit_profile_tile')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('nickname_field')),
      'Alice Updated',
    );
    await tester.enterText(
      find.byKey(const ValueKey('username_field')),
      'alice.updated',
    );
    await tester.tap(find.byKey(const ValueKey('save_profile_button')));
    await tester.pumpAndSettle();

    expect(gateway.updatedUsername, 'alice.updated');
    expect(gateway.updatedNickname, 'Alice Updated');
    expect(find.text('Alice Updated'), findsOneWidget);
  });

  testWidgets('storage details group usage by device and sync root', (
    tester,
  ) async {
    final gateway = FakeProfileGateway();
    await tester.pumpWidget(_profileApp(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('storage_usage_tile')));
    await tester.pumpAndSettle();

    expect(find.text('设备与空间'), findsWidgets);
    expect(find.text('2 台'), findsOneWidget);
    expect(find.text('Alice Phone'), findsOneWidget);
    expect(find.text('2.0 GB'), findsWidgets);
    await tester.tap(find.text('Alice Phone'));
    await tester.pumpAndSettle();
    expect(find.text('同步目录 root-123'), findsOneWidget);
    expect(find.text('12 个文件'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
  });

  testWidgets('device storage can remove a confirmed unused device', (
    tester,
  ) async {
    final gateway = FakeProfileGateway();
    await tester.pumpWidget(_profileApp(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('storage_usage_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Old Phone'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remove_device_device-old')));
    await tester.pumpAndSettle();

    expect(find.textContaining('不会删除服务器文件'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('confirm_remove_device_button')),
    );
    await tester.pumpAndSettle();

    expect(gateway.removedDeviceId, 'device-old');
    expect(gateway.removedCurrentDeviceId, 'device-1');
    expect(find.text('Old Phone'), findsNothing);
    expect(find.text('1 台'), findsOneWidget);
  });

  testWidgets(
    'app update resolves relative download URL and reports platform',
    (tester) async {
      final releaseGateway = FakeAppReleaseGateway();
      Uri? launchedUri;
      await tester.pumpWidget(
        _profileApp(
          gateway: FakeProfileGateway(),
          releaseGateway: releaseGateway,
          launchExternalUrl: (uri) async {
            launchedUri = uri;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('app_update_tile')),
        200,
        scrollable: find.byType(Scrollable),
      );
      await tester.drag(find.byType(Scrollable), const Offset(0, -160));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app_update_tile')));
      await tester.pumpAndSettle();

      expect(releaseGateway.requestedPlatform, 'android');
      expect(find.text('发现新版本'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('start_update_download_button')),
      );
      await tester.pumpAndSettle();

      expect(
        launchedUri,
        Uri.parse('https://files.example.com/downloads/vaultsync.apk'),
      );
      expect(find.textContaining('已交给系统下载'), findsOneWidget);
    },
  );

  testWidgets('password dialog validates confirmation before request', (
    tester,
  ) async {
    final gateway = FakeProfileGateway();
    await tester.pumpWidget(_profileApp(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('change_password_tile')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('current_password_field')),
      'old-passw0rd',
    );
    await tester.enterText(
      find.byKey(const ValueKey('new_password_field')),
      'new-passw0rd',
    );
    await tester.enterText(
      find.byKey(const ValueKey('confirm_password_field')),
      'different',
    );
    await tester.tap(find.byKey(const ValueKey('save_password_button')));
    await tester.pumpAndSettle();

    expect(find.text('两次输入的新密码不一致'), findsOneWidget);
    expect(gateway.changedPassword, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('confirm_password_field')),
      'new-passw0rd',
    );
    await tester.tap(find.byKey(const ValueKey('save_password_button')));
    await tester.pumpAndSettle();
    expect(gateway.changedPassword, 'new-passw0rd');
  });

  testWidgets('sign out explains which local data remains', (tester) async {
    var signedOut = false;
    await tester.pumpWidget(
      _profileApp(
        gateway: FakeProfileGateway(),
        onSignOut: () async => signedOut = true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('sign_out_button')),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.byKey(const ValueKey('sign_out_button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('本地目录绑定、上传队列'), findsOneWidget);
    expect(signedOut, isFalse);

    await tester.tap(find.byKey(const ValueKey('confirm_sign_out_button')));
    await tester.pumpAndSettle();
    expect(signedOut, isTrue);
  });

  testWidgets('profile settings fit a narrow phone viewport', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_profileApp(gateway: FakeProfileGateway()));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('profile_settings_list')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出登录'), findsOneWidget);
  });

  testWidgets('profile checks and requests sync permissions', (tester) async {
    final permissions = FakeAppPermissionGateway(
      const AppPermissionSnapshot(
        media: AppPermissionState.granted,
        allFiles: AppPermissionState.denied,
      ),
    );
    await tester.pumpWidget(
      _profileApp(
        gateway: FakeProfileGateway(),
        permissionGateway: permissions,
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('app_permissions_tile')),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.byKey(const ValueKey('app_permissions_tile')));
    await tester.pumpAndSettle();

    expect(find.text('权限与存储'), findsOneWidget);
    expect(find.text('有权限需要处理'), findsOneWidget);
    expect(find.text('照片和视频'), findsOneWidget);
    expect(find.text('共享文件夹访问'), findsOneWidget);

    permissions.snapshot = const AppPermissionSnapshot(
      media: AppPermissionState.granted,
      allFiles: AppPermissionState.granted,
    );
    final fileTile = find.byKey(const ValueKey('file_access_permission_tile'));
    await tester.tap(find.descendant(of: fileTile, matching: find.text('未授权')));
    await tester.pumpAndSettle();

    expect(permissions.fileRequestCount, 1);
    expect(find.text('同步权限已满足'), findsOneWidget);
  });

  testWidgets('macOS treats folder access as picker-managed', (tester) async {
    final permissions = FakeAppPermissionGateway(
      const AppPermissionSnapshot(
        media: AppPermissionState.granted,
        allFiles: AppPermissionState.notRequired,
      ),
    );
    await tester.pumpWidget(
      _profileApp(
        gateway: FakeProfileGateway(),
        permissionGateway: permissions,
        platform: 'macos',
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('app_permissions_tile')),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.byKey(const ValueKey('app_permissions_tile')));
    await tester.pumpAndSettle();

    expect(find.textContaining('macOS 照片图库'), findsOneWidget);
    expect(find.text('文件夹访问由系统目录选择器管理，选择同步目录时授予权限。'), findsOneWidget);
    expect(find.text('无需额外授权'), findsOneWidget);
    expect(find.text('未授权'), findsNothing);
    expect(permissions.fileRequestCount, 0);
  });
}

Widget _profileApp({
  required FakeProfileGateway gateway,
  Future<void> Function()? onSignOut,
  AppPermissionGateway? permissionGateway,
  AppReleaseGateway? releaseGateway,
  Future<bool> Function(Uri uri)? launchExternalUrl,
  String platform = 'android',
  VaultThemePreset selectedTheme = VaultThemePreset.celadon,
  Future<void> Function(VaultThemePreset theme)? onThemeChanged,
}) {
  return MaterialApp(
    home: ProfileScreen(
      storage: FakeSessionStore(),
      profileGateway: gateway,
      releaseGateway: releaseGateway,
      avatarStore: MemoryAvatarStore(),
      permissionGateway: permissionGateway,
      platform: platform,
      serverAddress: 'https://files.example.com',
      onSignOut: onSignOut,
      appVersionLoader: () async => '1.0.0+1',
      launchExternalUrl: launchExternalUrl,
      selectedTheme: selectedTheme,
      onThemeChanged: onThemeChanged,
    ),
  );
}

class FakeAppReleaseGateway implements AppReleaseGateway {
  String? requestedPlatform;

  @override
  Future<AppRelease> loadRelease(String platform) async {
    requestedPlatform = platform;
    return const AppRelease(
      platform: 'android',
      version: '1.1.0',
      downloadUrl: '/downloads/vaultsync.apk',
      sizeBytes: 1024,
      updatedAt: '2026-08-02T00:00:00Z',
    );
  }
}

class FakeAppPermissionGateway implements AppPermissionGateway {
  AppPermissionSnapshot snapshot;
  int fileRequestCount = 0;

  FakeAppPermissionGateway(this.snapshot);

  @override
  Future<AppPermissionSnapshot> checkPermissions() async => snapshot;

  @override
  Future<void> openSystemSettings() async {}

  @override
  Future<void> requestFileAccessPermission() async {
    fileRequestCount += 1;
  }

  @override
  Future<void> requestMediaPermission() async {}
}

class FakeProfileGateway implements UserProfileGateway, StorageUsageGateway {
  final Future<UserProfile> Function()? profileLoader;

  FakeProfileGateway({this.profileLoader});

  UserProfile profile = const UserProfile(
    id: 'user-1',
    email: 'alice@example.com',
    username: 'alice',
    nickname: 'Alice',
    quotaBytes: 10 * 1024 * 1024 * 1024,
    usedBytes: 2 * 1024 * 1024 * 1024,
  );
  int loadCount = 0;
  String? updatedUsername;
  String? updatedNickname;
  String? changedPassword;
  String? removedDeviceId;
  String? removedCurrentDeviceId;
  final List<DeviceStorageUsage> devices = [
    const DeviceStorageUsage(
      deviceId: 'device-1',
      deviceName: 'Alice Phone',
      platform: 'android',
      usedBytes: 2 * 1024 * 1024 * 1024,
      syncRoots: [
        SyncRootStorageUsage(
          syncRootId: 'root-123456789',
          encryptedPath: 'vaultsync-path:v1:root',
          usedBytes: 2 * 1024 * 1024 * 1024,
          fileCount: 12,
        ),
      ],
    ),
    const DeviceStorageUsage(
      deviceId: 'device-old',
      deviceName: 'Old Phone',
      platform: 'android',
      usedBytes: 0,
    ),
  ];

  @override
  Future<UserProfile> loadProfile(String token) async {
    loadCount += 1;
    return profileLoader?.call() ?? profile;
  }

  @override
  Future<StorageUsage> loadStorageUsage(String token) async {
    return StorageUsage(
      quotaBytes: 10 * 1024 * 1024 * 1024,
      usedBytes: 2 * 1024 * 1024 * 1024,
      devices: List.unmodifiable(devices),
    );
  }

  @override
  Future<void> removeDevice({
    required String token,
    required String deviceId,
    required String currentDeviceId,
  }) async {
    removedDeviceId = deviceId;
    removedCurrentDeviceId = currentDeviceId;
    devices.removeWhere((device) => device.deviceId == deviceId);
  }

  @override
  Future<UserProfile> updateProfile({
    required String token,
    required String username,
    required String nickname,
  }) async {
    updatedUsername = username;
    updatedNickname = nickname;
    profile = UserProfile(
      id: profile.id,
      email: profile.email,
      username: username,
      nickname: nickname,
      quotaBytes: profile.quotaBytes,
      usedBytes: profile.usedBytes,
    );
    return profile;
  }

  @override
  Future<void> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    changedPassword = newPassword;
  }
}

class MemoryAvatarStore implements AvatarStore {
  Uint8List? bytes;

  @override
  Future<Uint8List?> load(String userId) async => bytes;

  @override
  Future<void> save(String userId, Uint8List bytes) async {
    this.bytes = bytes;
  }
}

class FakeSessionStore implements SessionStore {
  @override
  Future<String?> loadAuthToken() async => 'server-token';

  @override
  Future<String?> loadAuthExpiresAt() async => '2999-01-01T00:00:00Z';

  @override
  Future<String?> loadDeviceId() async => 'device-1';

  @override
  Future<void> saveAuthSession(AuthSession session) async {}

  @override
  Future<void> saveDevice(RegisteredDevice device) async {}
}
