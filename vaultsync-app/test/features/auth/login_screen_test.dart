import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/device/device_profile.dart';
import 'package:vaultsync_app/core/network/api_exception.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/auth/auth_models.dart';
import 'package:vaultsync_app/features/auth/auth_service.dart';
import 'package:vaultsync_app/features/auth/login_screen.dart';
import 'package:vaultsync_app/features/device/device_models.dart';
import 'package:vaultsync_app/features/device/device_service.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/sync_service.dart';
import 'package:vaultsync_app/features/sync/upload_key_store.dart';

void main() {
  testWidgets('login screen calls auth service and opens sync home', (
    tester,
  ) async {
    final auth = FakeAuthGateway(
      result: const AuthSession(
        token: 'server-token',
        tokenId: 'token-1',
        userId: 'user-1',
        expiresAt: '2026-06-28T00:00:00Z',
      ),
    );
    final devices = FakeDeviceGateway();
    final storage = FakeSessionStore();
    final uploadKeys = FakeUploadKeyStore();
    final syncRootMappings = FakeSyncRootMappingStore();
    final uploadTasks = FakeUploadTaskStore();
    final syncRoots = FakeSyncRootGateway(const []);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          auth: auth,
          devices: devices,
          storage: storage,
          syncRootMappings: syncRootMappings,
          uploadTasks: uploadTasks,
          uploadKeys: uploadKeys,
          deviceProfile: const DeviceProfile(
            name: 'Alice iPhone',
            platform: 'ios',
          ),
          syncRoots: syncRoots,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('login_email_field')),
      'alice@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login_password_field')),
      'passw0rd!',
    );
    await tester.tap(find.byKey(const ValueKey('login_submit_button')));
    await tester.pumpAndSettle();

    expect(auth.email, 'alice@example.com');
    expect(auth.password, 'passw0rd!');
    expect(devices.token, 'server-token');
    expect(devices.name, 'Alice iPhone');
    expect(devices.platform, 'ios');
    expect(uploadKeys.email, 'alice@example.com');
    expect(uploadKeys.password, 'passw0rd!');
    expect(storage.savedSession?.token, 'server-token');
    expect(storage.savedDevice?.id, 'device-1');
    expect(syncRoots.token, 'server-token');
    expect(find.text('同步主页'), findsOneWidget);
    expect(find.byTooltip('返回'), findsNothing);
  });

  testWidgets('login screen shows auth error message', (tester) async {
    final auth = FakeAuthGateway(errorMessage: 'invalid email or password');
    final devices = FakeDeviceGateway();
    final storage = FakeSessionStore();
    final uploadKeys = FakeUploadKeyStore();
    final syncRootMappings = FakeSyncRootMappingStore();
    final uploadTasks = FakeUploadTaskStore();
    final syncRoots = FakeSyncRootGateway(const []);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          auth: auth,
          devices: devices,
          storage: storage,
          syncRootMappings: syncRootMappings,
          uploadTasks: uploadTasks,
          uploadKeys: uploadKeys,
          deviceProfile: const DeviceProfile(
            name: 'Alice iPhone',
            platform: 'ios',
          ),
          syncRoots: syncRoots,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('login_email_field')),
      'alice@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login_password_field')),
      'bad-password',
    );
    await tester.tap(find.byKey(const ValueKey('login_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('邮箱或密码不正确'), findsOneWidget);
    expect(find.text('同步主页'), findsNothing);
    expect(devices.token, isNull);
    expect(uploadKeys.email, isNull);
    expect(storage.savedSession, isNull);
    expect(syncRoots.token, isNull);
  });

  testWidgets('login screen shows device registration failure step', (
    tester,
  ) async {
    final auth = FakeAuthGateway(
      result: const AuthSession(
        token: 'server-token',
        tokenId: 'token-1',
        userId: 'user-1',
        expiresAt: '2026-06-28T00:00:00Z',
      ),
    );
    final devices = FakeDeviceGateway(errorMessage: 'network failed');
    final storage = FakeSessionStore();
    final uploadKeys = FakeUploadKeyStore();
    final syncRootMappings = FakeSyncRootMappingStore();
    final uploadTasks = FakeUploadTaskStore();
    final syncRoots = FakeSyncRootGateway(const []);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          auth: auth,
          devices: devices,
          storage: storage,
          syncRootMappings: syncRootMappings,
          uploadTasks: uploadTasks,
          uploadKeys: uploadKeys,
          deviceProfile: const DeviceProfile(
            name: 'Alice iPhone',
            platform: 'ios',
          ),
          syncRoots: syncRoots,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('login_email_field')),
      'alice@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login_password_field')),
      'passw0rd!',
    );
    await tester.tap(find.byKey(const ValueKey('login_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('登录已成功，但注册当前设备失败：操作失败，请稍后重试'), findsOneWidget);
    expect(storage.savedSession, isNull);
    expect(uploadKeys.email, isNull);
    expect(find.text('同步主页'), findsNothing);
  });

  testWidgets('login screen keeps server settings in dialog', (tester) async {
    final auth = FakeAuthGateway();
    final devices = FakeDeviceGateway();
    final storage = FakeSessionStore();
    final uploadKeys = FakeUploadKeyStore();
    final syncRootMappings = FakeSyncRootMappingStore();
    final uploadTasks = FakeUploadTaskStore();
    final syncRoots = FakeSyncRootGateway(const []);
    String? testedAddress;
    String? savedAddress;

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          auth: auth,
          devices: devices,
          storage: storage,
          syncRootMappings: syncRootMappings,
          uploadTasks: uploadTasks,
          uploadKeys: uploadKeys,
          deviceProfile: const DeviceProfile(
            name: 'Alice iPhone',
            platform: 'ios',
          ),
          syncRoots: syncRoots,
          serverAddress: 'http://127.0.0.1:8080',
          onTestServerConnection: (address) async {
            testedAddress = address;
          },
          onServerAddressChanged: (address) async {
            savedAddress = address;
          },
        ),
      ),
    );

    expect(find.textContaining('后端地址'), findsNothing);
    expect(find.text('测试连接'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('login_server_settings_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('服务器设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('server_address_field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('server_address_field')),
      'http://192.168.1.10:8080',
    );
    await tester.tap(find.byKey(const ValueKey('server_settings_test_button')));
    await tester.pumpAndSettle();

    expect(testedAddress, 'http://192.168.1.10:8080');
    expect(find.text('后端连接正常'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('server_settings_save_button')));
    await tester.pumpAndSettle();

    expect(savedAddress, 'http://192.168.1.10:8080');
    expect(find.text('服务器设置'), findsNothing);
  });

  testWidgets('server settings shows readable connection failure', (
    tester,
  ) async {
    final auth = FakeAuthGateway();
    final devices = FakeDeviceGateway();
    final storage = FakeSessionStore();
    final uploadKeys = FakeUploadKeyStore();
    final syncRootMappings = FakeSyncRootMappingStore();
    final uploadTasks = FakeUploadTaskStore();
    final syncRoots = FakeSyncRootGateway(const []);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          auth: auth,
          devices: devices,
          storage: storage,
          syncRootMappings: syncRootMappings,
          uploadTasks: uploadTasks,
          uploadKeys: uploadKeys,
          deviceProfile: const DeviceProfile(
            name: 'Alice iPhone',
            platform: 'ios',
          ),
          syncRoots: syncRoots,
          serverAddress: 'http://127.0.0.1:8080',
          onTestServerConnection: (_) async {
            throw const ApiException(
              statusCode: 0,
              code: 'connection_failed',
              message: '无法连接后端服务，请确认 VaultSync 后端已启动，或检查后端地址是否正确',
            );
          },
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('login_server_settings_button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('server_settings_test_button')));
    await tester.pumpAndSettle();

    expect(
      find.text('无法连接后端服务，请确认 VaultSync 后端已启动，或检查后端地址是否正确'),
      findsOneWidget,
    );
  });

  testWidgets('login screen registers account and opens sync home', (
    tester,
  ) async {
    final auth = FakeAuthGateway(
      result: const AuthSession(
        token: 'server-token',
        tokenId: 'token-1',
        userId: 'user-1',
        expiresAt: '2026-06-28T00:00:00Z',
      ),
    );
    final devices = FakeDeviceGateway();
    final storage = FakeSessionStore();
    final uploadKeys = FakeUploadKeyStore();
    final syncRootMappings = FakeSyncRootMappingStore();
    final uploadTasks = FakeUploadTaskStore();
    final syncRoots = FakeSyncRootGateway(const []);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          auth: auth,
          devices: devices,
          storage: storage,
          syncRootMappings: syncRootMappings,
          uploadTasks: uploadTasks,
          uploadKeys: uploadKeys,
          deviceProfile: const DeviceProfile(
            name: 'Alice iPhone',
            platform: 'ios',
          ),
          syncRoots: syncRoots,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('login_email_field')),
      'alice@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login_password_field')),
      'passw0rd!',
    );
    await tester.tap(find.byKey(const ValueKey('login_register_button')));
    await tester.pumpAndSettle();

    expect(auth.registerEmail, 'alice@example.com');
    expect(auth.registerPassword, 'passw0rd!');
    expect(auth.email, 'alice@example.com');
    expect(auth.password, 'passw0rd!');
    expect(storage.savedSession?.token, 'server-token');
    expect(find.text('同步主页'), findsOneWidget);
  });
}

class FakeAuthGateway implements AuthGateway {
  final AuthSession? result;
  final String? errorMessage;
  final String? pingErrorMessage;
  String? email;
  String? password;
  String? registerEmail;
  String? registerPassword;
  var pingCount = 0;

  FakeAuthGateway({this.result, this.errorMessage, this.pingErrorMessage});

  @override
  Future<AuthSession> login(String email, String password) async {
    this.email = email;
    this.password = password;
    final message = errorMessage;
    if (message != null) {
      throw ApiException(
        statusCode: 401,
        code: 'unauthorized',
        message: message,
      );
    }
    return result!;
  }

  @override
  Future<RegisteredUser> register(String email, String password) async {
    registerEmail = email;
    registerPassword = password;
    return const RegisteredUser(id: 'user-1', email: 'alice@example.com');
  }

  @override
  Future<AuthSession> refresh(String token) {
    throw UnimplementedError();
  }

  @override
  Future<void> ping() async {
    pingCount += 1;
    final message = pingErrorMessage;
    if (message != null) {
      throw ApiException(
        statusCode: 0,
        code: 'connection_failed',
        message: message,
      );
    }
  }
}

class FakeDeviceGateway implements DeviceGateway {
  final String? errorMessage;
  String? token;
  String? name;
  String? platform;

  FakeDeviceGateway({this.errorMessage});

  @override
  Future<RegisteredDevice> registerDevice({
    required String token,
    required String name,
    required String platform,
  }) async {
    this.token = token;
    this.name = name;
    this.platform = platform;
    final message = errorMessage;
    if (message != null) {
      throw ApiException(
        statusCode: 0,
        code: 'connection_failed',
        message: message,
      );
    }
    return const RegisteredDevice(
      id: 'device-1',
      userId: 'user-1',
      name: 'Alice iPhone',
      platform: 'ios',
      createdAt: '2026-06-27T00:00:00Z',
    );
  }
}

class FakeSessionStore implements SessionStore {
  AuthSession? savedSession;
  RegisteredDevice? savedDevice;

  @override
  Future<String?> loadAuthToken() async => savedSession?.token;

  @override
  Future<String?> loadAuthExpiresAt() async => savedSession?.expiresAt;

  @override
  Future<String?> loadDeviceId() async => savedDevice?.id;

  @override
  Future<void> saveAuthSession(AuthSession session) async {
    savedSession = session;
  }

  @override
  Future<void> saveDevice(RegisteredDevice device) async {
    savedDevice = device;
  }
}

class FakeUploadKeyStore implements UploadKeyStore {
  String? email;
  String? password;
  var material = const UploadKeyMaterial(
    contentKeyBytes: [1, 2, 3],
    metadataKeyBytes: [4, 5, 6],
  );

  @override
  Future<UploadKeyMaterial> deriveAndSaveUploadKeys({
    required String email,
    required String password,
  }) async {
    this.email = email;
    this.password = password;
    return material;
  }

  @override
  Future<UploadKeyMaterial> loadUploadKeys() async => material;
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
