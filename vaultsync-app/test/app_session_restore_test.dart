import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_app/app.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/auth/auth_models.dart';
import 'package:vaultsync_app/features/auth/auth_service.dart';
import 'package:vaultsync_app/features/device/device_models.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/sync_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('VaultSync app opens sync home when local session exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      VaultSyncApp(
        storage: FakeSessionStore(
          token: 'token-1',
          deviceId: 'dev-1',
          expiresAt: '2999-01-01T00:00:00Z',
        ),
        syncRootMappings: FakeSyncRootMappingStore(),
        uploadTasks: FakeUploadTaskStore(),
        syncIssues: FakeSyncIssueStore(),
        syncRoots: FakeSyncRootGateway(const []),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('同步主页'), findsOneWidget);
    expect(find.text('登录'), findsNothing);
  });

  testWidgets('VaultSync app opens login when local session is incomplete', (
    tester,
  ) async {
    await tester.pumpWidget(
      VaultSyncApp(
        storage: FakeSessionStore(),
        syncIssues: FakeSyncIssueStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录'), findsOneWidget);
    expect(find.text('同步主页'), findsNothing);
  });

  testWidgets('VaultSync app loads saved server address for login settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      VaultSyncApp(
        storage: FakeSessionStore(),
        serverSettings: FakeServerSettingsStore(
          serverAddress: 'http://192.168.1.10:8080',
        ),
        syncIssues: FakeSyncIssueStore(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('login_server_settings_button')),
    );
    await tester.pumpAndSettle();

    final addressField = tester.widget<TextField>(
      find.byKey(const ValueKey('server_address_field')),
    );
    expect(addressField.controller?.text, 'http://192.168.1.10:8080');
  });

  testWidgets('VaultSync app saves server address from login settings', (
    tester,
  ) async {
    final serverSettings = FakeServerSettingsStore();
    await tester.pumpWidget(
      VaultSyncApp(
        storage: FakeSessionStore(),
        serverSettings: serverSettings,
        syncIssues: FakeSyncIssueStore(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('login_server_settings_button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('server_address_field')),
      'http://192.168.1.20:8080',
    );
    await tester.tap(find.byKey(const ValueKey('server_settings_save_button')));
    await tester.pumpAndSettle();

    expect(serverSettings.savedServerAddress, 'http://192.168.1.20:8080');
    expect(find.text('服务器设置'), findsNothing);
  });

  testWidgets('VaultSync app opens login when local token is expired', (
    tester,
  ) async {
    await tester.pumpWidget(
      VaultSyncApp(
        storage: FakeSessionStore(
          token: 'token-1',
          deviceId: 'dev-1',
          expiresAt: '2000-01-01T00:00:00Z',
        ),
        syncIssues: FakeSyncIssueStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录'), findsOneWidget);
    expect(find.text('同步主页'), findsNothing);
  });

  testWidgets('VaultSync app refreshes local token before opening sync home', (
    tester,
  ) async {
    final storage = FakeSessionStore(
      token: 'old-token',
      deviceId: 'dev-1',
      expiresAt: DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 30))
          .toIso8601String(),
    );
    final auth = FakeAuthGateway(
      refreshed: AuthSession(
        token: 'new-token',
        tokenId: 'token-2',
        userId: 'user-1',
        expiresAt: DateTime.now()
            .toUtc()
            .add(const Duration(hours: 24))
            .toIso8601String(),
      ),
    );
    final syncRoots = FakeSyncRootGateway(const []);

    await tester.pumpWidget(
      VaultSyncApp(
        storage: storage,
        authGateway: auth,
        syncRootMappings: FakeSyncRootMappingStore(),
        uploadTasks: FakeUploadTaskStore(),
        syncIssues: FakeSyncIssueStore(),
        syncRoots: syncRoots,
      ),
    );
    await tester.pumpAndSettle();

    expect(auth.refreshToken, 'old-token');
    expect(storage.savedSession?.token, 'new-token');
    expect(syncRoots.token, 'new-token');
    expect(find.text('同步主页'), findsOneWidget);
  });
}

class FakeServerSettingsStore implements ServerSettingsStore {
  final String? serverAddress;
  String? savedServerAddress;

  FakeServerSettingsStore({this.serverAddress});

  @override
  Future<String?> loadServerAddress() async =>
      savedServerAddress ?? serverAddress;

  @override
  Future<void> saveServerAddress(String address) async {
    savedServerAddress = address;
  }
}

class FakeSessionStore implements SessionStore {
  final String? token;
  final String? deviceId;
  final String? expiresAt;
  AuthSession? savedSession;

  FakeSessionStore({this.token, this.deviceId, this.expiresAt});

  @override
  Future<String?> loadAuthToken() async => savedSession?.token ?? token;

  @override
  Future<String?> loadDeviceId() async => deviceId;

  @override
  Future<String?> loadAuthExpiresAt() async =>
      savedSession?.expiresAt ?? expiresAt;

  @override
  Future<void> saveAuthSession(AuthSession session) async {
    savedSession = session;
  }

  @override
  Future<void> saveDevice(RegisteredDevice device) async {}
}

class FakeAuthGateway implements AuthGateway {
  final AuthSession refreshed;
  String? refreshToken;

  FakeAuthGateway({required this.refreshed});

  @override
  Future<AuthSession> refresh(String token) async {
    refreshToken = token;
    return refreshed;
  }

  @override
  Future<AuthSession> login(String email, String password) {
    throw UnimplementedError();
  }

  @override
  Future<RegisteredUser> register(String email, String password) {
    throw UnimplementedError();
  }

  @override
  Future<void> ping() async {}
}

class FakeSyncRootMappingStore implements SyncRootMappingStore {
  @override
  Future<List<LocalSyncRootMapping>> loadSyncRootMappings() async => const [];

  @override
  Future<void> saveSyncRootMapping(LocalSyncRootMapping mapping) async {}

  @override
  Future<void> saveSyncRootMappings(
    List<LocalSyncRootMapping> mappings,
  ) async {}
}

class FakeUploadTaskStore implements UploadTaskStore {
  @override
  Future<List<LocalUploadTask>> loadUploadTasks() async => const [];

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {}
}

class FakeSyncIssueStore implements SyncIssueStore {
  @override
  Future<List<LocalSyncIssue>> loadSyncIssues() async => const [];

  @override
  Future<void> saveSyncIssue(LocalSyncIssue issue) async {}

  @override
  Future<void> markSyncIssueResolved({required String issueId}) async {}
}

class FakeSyncRootGateway implements SyncRootGateway {
  final List<SyncRoot> roots;
  String? token;

  FakeSyncRootGateway(this.roots);

  @override
  Future<List<SyncRoot>> listSyncRoots({required String token}) async {
    this.token = token;
    return roots;
  }

  @override
  Future<SyncRoot> createSyncRoot({
    required String token,
    required String deviceId,
    required String encryptedPath,
    required String cleanupPolicy,
    required String archivePath,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<SyncRoot> updateSyncRootCleanupPolicy({
    required String token,
    required String syncRootId,
    required String cleanupPolicy,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteSyncRoot({
    required String token,
    required String syncRootId,
    required bool deleteRemote,
  }) {
    throw UnimplementedError();
  }
}
