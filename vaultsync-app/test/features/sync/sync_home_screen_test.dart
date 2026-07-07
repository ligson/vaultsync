import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/network/api_exception.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/auth/auth_models.dart';
import 'package:vaultsync_app/features/device/device_models.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_gateway.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_models.dart';
import 'package:vaultsync_app/features/sync/file_access_permission.dart';
import 'package:vaultsync_app/features/sync/folder_picker.dart';
import 'package:vaultsync_app/features/sync/local_path_protector.dart';
import 'package:vaultsync_app/features/sync/local_sync_scanner.dart';
import 'package:vaultsync_app/features/sync/local_upload_executor.dart';
import 'package:vaultsync_app/features/sync/remote_metadata_decrypter.dart';
import 'package:vaultsync_app/features/sync/sync_home_screen.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/sync_pull_executor.dart';
import 'package:vaultsync_app/features/sync/sync_service.dart';

void main() {
  testWidgets('sync home lists sync roots from local session token', (
    tester,
  ) async {
    final syncRoots = FakeSyncRootGateway([
      const SyncRoot(
        id: 'root-1',
        userId: 'user-1',
        deviceId: 'device-1',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'delete',
        archivePath: '',
        createdAt: '2026-06-27T00:00:00Z',
      ),
    ]);
    final mappings = FakeSyncRootMappingStore([
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
    ]);
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:2026/a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/2026/a.jpg',
        relativePath: '2026/a.jpg',
        sizeBytes: 2048,
        modifiedAt: DateTime.utc(2026, 6, 27, 9, 30),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: mappings,
          uploadTasks: uploadTasks,
          syncRoots: syncRoots,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(syncRoots.token, 'server-token');
    expect(find.text('同步主页'), findsOneWidget);
    expect(find.text('Photos'), findsWidgets);
    expect(find.text('/Users/alice/Photos'), findsOneWidget);
    expect(find.text('1 个文件'), findsWidgets);
    expect(find.text('待上传'), findsWidgets);

    expect(find.text('2026'), findsOneWidget);
    await tester.tap(find.text('2026'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.textContaining('2026/a.jpg'), findsOneWidget);
    expect(find.textContaining('2.0 KB · 2026-06-27 17:30'), findsOneWidget);
    expect(find.text('清理策略：上传后删除'), findsOneWidget);
  });

  testWidgets('sync home shows empty state when no sync roots exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway(const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无同步目录'), findsOneWidget);
  });

  testWidgets('sync home opens media backup screen on mobile', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway(const []),
          devicePlatform: 'android',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open_media_backup_button')));
    await tester.pumpAndSettle();

    expect(find.text('相册备份'), findsOneWidget);
  });

  testWidgets('sync home shows media backup root as album backup', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'delete',
              archivePath: '',
            ),
          ]),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'delete',
              archivePath: '',
              createdAt: '2026-07-03T01:00:00Z',
            ),
          ]),
          devicePlatform: 'android',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('相册备份'), findsOneWidget);
    expect(find.text('手机相册照片和视频'), findsOneWidget);
    expect(find.textContaining('未绑定目录'), findsNothing);
  });

  testWidgets('sync home asks for album permission when media scan is denied', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'keep',
              archivePath: '',
            ),
          ]),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-03T01:00:00Z',
            ),
          ]),
          localScanner: FakeLocalSyncScanner(const []),
          mediaBackupSources: FakeMediaBackupSourceStore([
            LocalMediaBackupSource(
              id: 'source-1',
              syncRootId: 'root-1',
              name: '相册备份',
              mediaTypes: 'image_video',
              albumScope: 'all',
              albumIds: const [],
              cleanupPolicy: 'keep',
              wifiOnly: true,
              autoBackupEnabled: true,
              createdAt: DateTime.utc(2026, 7, 3),
              updatedAt: DateTime.utc(2026, 7, 3),
            ),
          ]),
          mediaGateway: FakeMediaBackupGateway(
            permission: const MediaPermissionStatus(
              state: 'denied',
              message: '未获得相册访问权限',
            ),
          ),
          devicePlatform: 'android',
          autoSyncEnabled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scan_local_files_button')));
    await tester.pumpAndSettle();

    expect(find.text('未获得相册访问权限'), findsOneWidget);
  });

  testWidgets(
    'sync home asks for album permission when local media source is missing',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SyncHomeScreen(
            storage: FakeSessionStore(
              token: 'server-token',
              deviceId: 'device-1',
            ),
            syncRootMappings: FakeSyncRootMappingStore([
              const LocalSyncRootMapping(
                syncRootId: 'root-1',
                localPath: '',
                encryptedPath: 'media-backup:v1:source-1',
                cleanupPolicy: 'keep',
                archivePath: '',
              ),
            ]),
            uploadTasks: FakeUploadTaskStore(),
            syncRoots: FakeSyncRootGateway([
              const SyncRoot(
                id: 'root-1',
                userId: 'user-1',
                deviceId: 'device-1',
                encryptedPath: 'media-backup:v1:source-1',
                cleanupPolicy: 'keep',
                archivePath: '',
                createdAt: '2026-07-03T01:00:00Z',
              ),
            ]),
            localScanner: FakeLocalSyncScanner(const []),
            mediaBackupSources: FakeMediaBackupSourceStore(),
            mediaGateway: FakeMediaBackupGateway(
              permission: const MediaPermissionStatus(
                state: 'denied',
                message: '未获得相册访问权限',
              ),
            ),
            devicePlatform: 'android',
            autoSyncEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('scan_local_files_button')));
      await tester.pumpAndSettle();

      expect(find.text('未获得相册访问权限'), findsOneWidget);
    },
  );

  testWidgets('sync home asks for album permission before scanning DCIM', (
    tester,
  ) async {
    final scanner = FakeLocalSyncScanner(const []);
    final mediaGateway = FakeMediaBackupGateway(
      permission: const MediaPermissionStatus(
        state: 'denied',
        message: '未获得相册访问权限',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '/sdcard/DCIM',
              encryptedPath: 'vaultsync-path:v1:dcim',
              cleanupPolicy: 'keep',
              archivePath: '',
            ),
          ]),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'vaultsync-path:v1:dcim',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-03T01:00:00Z',
            ),
          ]),
          localScanner: scanner,
          mediaGateway: mediaGateway,
          devicePlatform: 'android',
          autoSyncEnabled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scan_local_files_button')));
    await tester.pumpAndSettle();

    expect(mediaGateway.requestCount, 1);
    expect(scanner.callCount, 0);
    expect(find.text('未获得相册访问权限'), findsOneWidget);
  });

  testWidgets('sync home opens sync history page and clears history', (
    tester,
  ) async {
    final history = FakeSyncHistoryStore([
      LocalSyncHistoryEntry(
        id: 'history-1',
        type: 'upload',
        result: 'success',
        title: '上传待处理任务',
        message: '已上传 2 个任务，失败 0 个',
        syncRootId: 'root-1',
        relativePath: 'photos/a.jpg',
        createdAt: DateTime.utc(2026, 7, 2, 10),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncHistory: history,
          syncRoots: FakeSyncRootGateway(const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open_sync_history_button')));
    await tester.pumpAndSettle();

    expect(find.text('同步记录'), findsOneWidget);
    expect(find.text('上传待处理任务'), findsOneWidget);
    expect(find.textContaining('已上传 2 个任务'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('clear_sync_history_button')));
    await tester.pumpAndSettle();

    expect(history.entries, isEmpty);
    expect(find.text('暂无同步记录'), findsOneWidget);
  });

  testWidgets('sync home exposes sign out action', (tester) async {
    var signedOut = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway(const []),
          onSignOut: () async {
            signedOut = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sign_out_button')));
    await tester.pumpAndSettle();

    expect(signedOut, isTrue);
  });

  testWidgets('sync home prunes local roots not owned by current user', (
    tester,
  ) async {
    final mappings = FakeSyncRootMappingStore([
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'keep',
        archivePath: '',
      ),
      const LocalSyncRootMapping(
        syncRootId: 'old-root',
        localPath: '/Users/alice/Old',
        encryptedPath: 'base64:old',
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
    ]);
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 1,
        modifiedAt: DateTime.utc(2026, 7),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7),
      ),
      LocalUploadTask(
        id: 'old-root:b.jpg',
        syncRootId: 'old-root',
        localPath: '/Users/alice/Old/b.jpg',
        relativePath: 'b.jpg',
        sizeBytes: 1,
        modifiedAt: DateTime.utc(2026, 7),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: mappings,
          uploadTasks: uploadTasks,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(mappings.saved.map((mapping) => mapping.syncRootId), ['root-1']);
    expect(uploadTasks.saved.map((task) => task.syncRootId), ['root-1']);
    expect(find.text('/Users/alice/Old'), findsNothing);
  });

  testWidgets('sync error view can return to login on invalid token', (
    tester,
  ) async {
    var signedOut = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(token: 'bad-token', deviceId: 'device-1'),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: ThrowingSyncRootGateway(
            const ApiException(
              statusCode: 401,
              code: 'unauthorized',
              message: 'invalid bearer token',
            ),
          ),
          onSignOut: () async {
            signedOut = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录状态已失效，请重新登录'), findsOneWidget);
    expect(find.text('返回登录'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('error_sign_out_button')));
    await tester.pumpAndSettle();

    expect(signedOut, isTrue);
  });

  testWidgets('sync home clearly shows server backed files deleted locally', (
    tester,
  ) async {
    final syncRoots = FakeSyncRootGateway([
      const SyncRoot(
        id: 'root-1',
        userId: 'user-1',
        deviceId: 'device-1',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'delete',
        archivePath: '',
        createdAt: '2026-06-27T00:00:00Z',
      ),
    ]);
    final mappings = FakeSyncRootMappingStore([
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
    ]);
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:2026/a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/2026/a.jpg',
        relativePath: '2026/a.jpg',
        sizeBytes: 2048,
        modifiedAt: DateTime.utc(2026, 6, 27, 9, 30),
        status: 'deleted_local',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: mappings,
          uploadTasks: uploadTasks,
          syncRoots: syncRoots,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已备份'), findsOneWidget);
    expect(find.text('本地已清理：1'), findsOneWidget);
    await tester.tap(find.text('2026'));
    await tester.pumpAndSettle();
    expect(find.text('服务器已备份，本地已删除'), findsOneWidget);
    expect(find.text('删除策略下，1 个文件已完成服务器备份，本地已按策略清理。'), findsOneWidget);
  });

  testWidgets('sync home shows partial backup status for mixed cleanup tasks', (
    tester,
  ) async {
    final syncRoots = FakeSyncRootGateway([
      const SyncRoot(
        id: 'root-1',
        userId: 'user-1',
        deviceId: 'device-1',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'delete',
        archivePath: '',
        createdAt: '2026-06-27T00:00:00Z',
      ),
    ]);
    final mappings = FakeSyncRootMappingStore([
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
    ]);
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:2026/a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/2026/a.jpg',
        relativePath: '2026/a.jpg',
        sizeBytes: 2048,
        modifiedAt: DateTime.utc(2026, 6, 27, 9, 30),
        status: 'deleted_local',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
      LocalUploadTask(
        id: 'root-1:2026/b.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/2026/b.jpg',
        relativePath: '2026/b.jpg',
        sizeBytes: 1024,
        modifiedAt: DateTime.utc(2026, 6, 27, 9, 31),
        status: 'clean',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: mappings,
          uploadTasks: uploadTasks,
          syncRoots: syncRoots,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('部分已备份'), findsOneWidget);
    expect(find.text('本地已清理：1'), findsOneWidget);
  });

  testWidgets('sync home shows server backup tree from remote objects', (
    tester,
  ) async {
    final syncRoots = FakeSyncRootGateway([
      const SyncRoot(
        id: 'root-1',
        userId: 'user-1',
        deviceId: 'device-1',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'delete',
        archivePath: '',
        createdAt: '2026-06-27T00:00:00Z',
      ),
    ]);
    final mappings = FakeSyncRootMappingStore([
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
    ]);
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:2026/a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/2026/a.jpg',
        relativePath: '2026/a.jpg',
        sizeBytes: 2048,
        modifiedAt: DateTime.utc(2026, 6, 27, 9, 30),
        status: 'deleted_local',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
    ]);
    final remoteBackups = FakeRemoteBackupGateway([
      const RemoteBackupObject(
        cursorValue: 1,
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        encryptedName: 'enc:a',
        contentHash: 'sha256:a',
        sizeBytes: 4096,
        metadataJson: '{}',
        updatedAt: '2026-07-01T10:00:00Z',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: mappings,
          uploadTasks: uploadTasks,
          syncRoots: syncRoots,
          remoteBackups: remoteBackups,
          remoteMetadataDecrypter: const FakeRemoteMetadataDecrypter({
            'object-1': RemoteBackupEntry(
              syncRootId: 'root-1',
              objectId: 'object-1',
              versionId: 'version-1',
              name: 'a.jpg',
              relativePath: '2026/a.jpg',
              sizeBytes: 4096,
              updatedAt: '2026-07-01T10:00:00Z',
            ),
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(remoteBackups.token, 'server-token');
    expect(remoteBackups.syncRootId, 'root-1');
    expect(find.text('1 个文件'), findsWidgets);
    expect(find.text('2026'), findsOneWidget);
    await tester.tap(find.text('2026'));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.textContaining('2026/a.jpg · 4.0 KB'), findsOneWidget);
    expect(find.text('服务器已备份，本地已删除'), findsOneWidget);
  });

  testWidgets('sync home can delete one server backed file', (tester) async {
    final remoteBackups = FakeRemoteBackupGateway([
      const RemoteBackupObject(
        cursorValue: 1,
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        encryptedName: 'enc:a',
        contentHash: 'sha256:a',
        sizeBytes: 4096,
        metadataJson: '{}',
        updatedAt: '2026-07-01T10:00:00Z',
      ),
    ]);
    final deletes = FakeRemoteObjectDeleteGateway();

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '/Users/alice/Photos',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
            ),
          ]),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-06-27T00:00:00Z',
            ),
          ]),
          remoteBackups: remoteBackups,
          remoteObjectDeletes: deletes,
          remoteMetadataDecrypter: const FakeRemoteMetadataDecrypter({
            'object-1': RemoteBackupEntry(
              syncRootId: 'root-1',
              objectId: 'object-1',
              versionId: 'version-1',
              name: 'a.jpg',
              relativePath: '2026/a.jpg',
              sizeBytes: 4096,
              updatedAt: '2026-07-01T10:00:00Z',
            ),
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除服务器备份'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除备份'));
    await tester.pumpAndSettle();

    expect(deletes.token, 'server-token');
    expect(deletes.deviceId, 'device-1');
    expect(deletes.syncRootId, 'root-1');
    expect(deletes.objectIds, ['object-1']);
    expect(find.text('已删除 1 个服务器备份'), findsOneWidget);
  });

  testWidgets('sync home creates sync root and refreshes list', (tester) async {
    final syncRoots = FakeSyncRootGateway(const []);
    final mappings = FakeSyncRootMappingStore();

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: mappings,
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: syncRoots,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('add_sync_root_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('sync_root_encrypted_path_field')),
      'base64:new-path',
    );
    await tester.tap(find.byKey(const ValueKey('save_sync_root_button')));
    await tester.pumpAndSettle();

    expect(syncRoots.createdToken, 'server-token');
    expect(syncRoots.createdDeviceId, 'device-1');
    expect(syncRoots.createdEncryptedPath, 'base64:new-path');
    expect(syncRoots.createdCleanupPolicy, 'keep');
    expect(mappings.saved.single.syncRootId, 'root-1');
    expect(mappings.saved.single.localPath, '');
    expect(mappings.saved.single.encryptedPath, 'base64:new-path');
    expect(syncRoots.listCallCount, 2);
    expect(find.text('未绑定目录 root-1'), findsWidgets);
    expect(find.text('未扫描'), findsOneWidget);
  });

  testWidgets('sync home can bind local folder for unbound server root', (
    tester,
  ) async {
    final mappings = FakeSyncRootMappingStore();

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: mappings,
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'protected:/Users/alice/Photos',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
          folderPicker: FakeFolderPicker('/Users/alice/Photos'),
          pathProtector: const FakePathProtector(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本机未绑定路径，可在目录操作中重新绑定'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('sync_root_quick_actions_root-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定本地目录'));
    await tester.pumpAndSettle();

    expect(mappings.saved.single.syncRootId, 'root-1');
    expect(mappings.saved.single.localPath, '/Users/alice/Photos');
    expect(find.text('/Users/alice/Photos'), findsOneWidget);
    expect(find.text('已绑定本地目录'), findsOneWidget);
  });

  testWidgets(
    'sync root dialog shows Chinese cleanup policies without archive option',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SyncHomeScreen(
            storage: FakeSessionStore(
              token: 'server-token',
              deviceId: 'device-1',
            ),
            syncRootMappings: FakeSyncRootMappingStore(),
            uploadTasks: FakeUploadTaskStore(),
            syncRoots: FakeSyncRootGateway(const []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('add_sync_root_button')));
      await tester.pumpAndSettle();

      expect(find.text('保留本地文件'), findsOneWidget);
      expect(find.text('keep'), findsNothing);
      expect(
        find.byKey(const ValueKey('sync_root_archive_path_field')),
        findsNothing,
      );
      expect(find.text('归档路径'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('sync_root_cleanup_policy_field')),
      );
      await tester.pumpAndSettle();

      expect(find.text('保留本地文件'), findsWidgets);
      expect(find.text('上传后删除本地文件'), findsOneWidget);
      expect(find.text('delete'), findsNothing);
      expect(find.text('archive'), findsNothing);
    },
  );

  testWidgets(
    'sync home selects local folder and protects path before create',
    (tester) async {
      final syncRoots = FakeSyncRootGateway(const []);
      final mappings = FakeSyncRootMappingStore();
      final fileAccessPermission = FakeFileAccessPermissionGateway();

      await tester.pumpWidget(
        MaterialApp(
          home: SyncHomeScreen(
            storage: FakeSessionStore(
              token: 'server-token',
              deviceId: 'device-1',
            ),
            syncRootMappings: mappings,
            uploadTasks: FakeUploadTaskStore(),
            syncRoots: syncRoots,
            folderPicker: FakeFolderPicker('/Users/alice/Photos'),
            fileAccessPermission: fileAccessPermission,
            pathProtector: const FakePathProtector(),
            devicePlatform: 'android',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('add_sync_root_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Download/VaultSync'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('open_file_access_settings_button')),
      );
      await tester.pumpAndSettle();
      expect(fileAccessPermission.openCount, 1);
      expect(find.textContaining('授权完成后请返回 VaultSync'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('choose_sync_folder_button')));
      await tester.pumpAndSettle();
      expect(find.text('/Users/alice/Photos'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('save_sync_root_button')));
      await tester.pumpAndSettle();

      expect(syncRoots.createdEncryptedPath, 'protected:/Users/alice/Photos');
      expect(syncRoots.createdEncryptedPath, isNot('/Users/alice/Photos'));
      expect(mappings.saved.single.syncRootId, 'root-1');
      expect(mappings.saved.single.localPath, '/Users/alice/Photos');
      expect(
        mappings.saved.single.encryptedPath,
        'protected:/Users/alice/Photos',
      );
    },
  );

  testWidgets(
    'android sync root dialog can use downloads path without tree picker',
    (tester) async {
      final syncRoots = FakeSyncRootGateway(const []);
      final mappings = FakeSyncRootMappingStore();

      await tester.pumpWidget(
        MaterialApp(
          home: SyncHomeScreen(
            storage: FakeSessionStore(
              token: 'server-token',
              deviceId: 'device-1',
            ),
            syncRootMappings: mappings,
            uploadTasks: FakeUploadTaskStore(),
            syncRoots: syncRoots,
            folderPicker: FakeFolderPicker(null),
            pathProtector: const FakePathProtector(),
            devicePlatform: 'android',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('add_sync_root_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('use_downloads_path_button')));
      await tester.pumpAndSettle();

      expect(find.text('/storage/emulated/0/Download'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('save_sync_root_button')));
      await tester.pumpAndSettle();

      expect(
        syncRoots.createdEncryptedPath,
        'protected:/storage/emulated/0/Download',
      );
      expect(mappings.saved.single.localPath, '/storage/emulated/0/Download');
    },
  );

  testWidgets('sync home scans local mapped files', (tester) async {
    final scanner = FakeLocalSyncScanner([
      LocalSyncFile(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27),
      ),
      LocalSyncFile(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/b.jpg',
        relativePath: 'b.jpg',
        sizeBytes: 5,
        modifiedAt: DateTime.utc(2026, 6, 27),
      ),
    ]);
    final uploadTasks = FakeUploadTaskStore();
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: uploadTasks,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
          localScanner: scanner,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scan_local_files_button')));
    await tester.pumpAndSettle();

    expect(scanner.callCount, 1);
    expect(scanner.syncRootId, isNull);
    expect(uploadTasks.saved, hasLength(2));
    expect(uploadTasks.saved.first.status, 'pending');
    expect(find.text('扫描发现 2 个本地文件，生成 2 个待上传任务'), findsOneWidget);
  });

  testWidgets('sync home can scan one sync root from row menu', (tester) async {
    final scanner = FakeLocalSyncScanner([
      LocalSyncFile(
        syncRootId: 'root-2',
        localPath: '/Users/alice/Docs/b.jpg',
        relativePath: 'b.jpg',
        sizeBytes: 5,
        modifiedAt: DateTime.utc(2026, 6, 27),
      ),
    ]);
    final uploadTasks = FakeUploadTaskStore();
    final history = FakeSyncHistoryStore();

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: uploadTasks,
          syncHistory: history,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path-1',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
            const SyncRoot(
              id: 'root-2',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path-2',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
          localScanner: scanner,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('sync_root_quick_actions_root-2')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫描此目录'));
    await tester.pumpAndSettle();

    expect(scanner.callCount, 1);
    expect(scanner.syncRootId, 'root-2');
    expect(uploadTasks.saved.single.syncRootId, 'root-2');
    expect(history.entries.single.title, '扫描单个同步目录');
    expect(history.entries.single.message, '发现 1 个本地文件，生成 1 个待上传任务');
    expect(history.entries.single.syncRootId, 'root-2');
    expect(find.text('扫描此目录发现 1 个本地文件，生成 1 个待上传任务'), findsOneWidget);
  });

  testWidgets('sync home executes pending uploads', (tester) async {
    final uploadExecutor = FakeUploadExecutor(uploadedCount: 2);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway(const []),
          uploadExecutor: uploadExecutor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('execute_uploads_button')));
    await tester.pumpAndSettle();

    expect(uploadExecutor.callCount, 1);
    expect(uploadExecutor.syncRootId, isNull);
    expect(find.text('已上传 2 个任务'), findsOneWidget);
  });

  testWidgets('sync status page shows failed uploads and can retry them', (
    tester,
  ) async {
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27),
        status: 'failed',
        attempts: 1,
        createdAt: DateTime.utc(2026, 6, 27),
        lastError: '网络暂时不可用',
      ),
    ]);
    final uploadExecutor = FakeUploadExecutor(uploadedCount: 1);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '/Users/alice/Photos',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
            ),
          ]),
          uploadTasks: uploadTasks,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
          uploadExecutor: uploadExecutor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sync_status_center')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
    await tester.pumpAndSettle();

    expect(find.text('同步状态'), findsWidgets);
    expect(find.byKey(const ValueKey('sync_status_center')), findsOneWidget);
    expect(find.text('上传失败：1'), findsWidgets);
    expect(find.text('重试 1 个失败任务'), findsOneWidget);
    expect(find.text('上传失败：1'), findsWidgets);
    expect(find.textContaining('网络暂时不可用'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('retry_failed_uploads_button')));
    await tester.pumpAndSettle();

    expect(uploadExecutor.callCount, 1);
    expect(uploadTasks.saved.single.status, 'pending');
    expect(uploadTasks.saved.single.lastError, '');
    expect(find.text('已上传 1 个任务'), findsOneWidget);
  });

  testWidgets('sync status page shows cleanup pending tasks and retries them', (
    tester,
  ) async {
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27),
        status: 'cleanup_pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27),
        lastError: '删除本地文件失败，请检查文件权限或是否被占用',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '/Users/alice/Photos',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
            ),
          ]),
          uploadTasks: uploadTasks,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('待清理：1'), findsWidgets);
    expect(find.text('重试 1 个清理任务'), findsOneWidget);
    expect(find.text('待清理任务 1 个'), findsOneWidget);
    expect(find.textContaining('删除本地文件失败'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('retry_cleanup_pending_button')),
    );
    await tester.pumpAndSettle();

    expect(uploadTasks.saved.single.status, 'clean');
    expect(find.text('已重试清理，完成 1 个，仍待处理 0 个'), findsOneWidget);
  });

  testWidgets('sync status page can ignore one cleanup pending task', (
    tester,
  ) async {
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27),
        status: 'cleanup_pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27),
        lastError: '本地文件已变化，暂不自动删除，请确认后重试',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '/Users/alice/Photos',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'delete',
              archivePath: '',
            ),
          ]),
          uploadTasks: uploadTasks,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'delete',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('cleanup_task_actions_root-1:a.jpg')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('忽略此项'));
    await tester.pumpAndSettle();

    expect(uploadTasks.saved.single.status, 'cleanup_ignored');
    expect(find.text('已忽略此项本地清理提醒'), findsOneWidget);
  });

  testWidgets(
    'sync status shows media cleanup page entry for media pending tasks',
    (tester) async {
      final uploadTasks = FakeUploadTaskStore([
        LocalUploadTask(
          id: 'root-1:asset-1',
          syncRootId: 'root-1',
          localPath: 'asset://asset-1',
          relativePath: 'IMG_0001.jpg',
          sizeBytes: 3,
          modifiedAt: DateTime.utc(2026, 7, 3),
          status: 'cleanup_pending',
          attempts: 0,
          createdAt: DateTime.utc(2026, 7, 3),
          lastError: '相册资源已备份，等待你确认后再删除本地照片和视频',
          sourceType: 'media_asset',
          assetId: 'asset-1',
          assetMediaType: 'image',
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: SyncHomeScreen(
            storage: FakeSessionStore(
              token: 'server-token',
              deviceId: 'device-1',
            ),
            syncRootMappings: FakeSyncRootMappingStore([
              const LocalSyncRootMapping(
                syncRootId: 'root-1',
                localPath: '',
                encryptedPath: 'media-backup:v1:source-1',
                cleanupPolicy: 'delete',
                archivePath: '',
              ),
            ]),
            uploadTasks: uploadTasks,
            syncRoots: FakeSyncRootGateway([
              const SyncRoot(
                id: 'root-1',
                userId: 'user-1',
                deviceId: 'device-1',
                encryptedPath: 'media-backup:v1:source-1',
                cleanupPolicy: 'delete',
                archivePath: '',
                createdAt: '2026-07-03T01:00:00Z',
              ),
            ]),
            mediaGateway: FakeMediaBackupGateway(
              permission: const MediaPermissionStatus(state: 'authorized'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('open_media_cleanup_page_button')),
        findsOneWidget,
      );
      expect(find.text('查看待清理照片和视频'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('retry_cleanup_pending_button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('retry_cleanup_pending_list_button')),
        findsNothing,
      );
      expect(find.text('待清理任务 1 个'), findsNothing);
      expect(find.text('IMG_0001.jpg'), findsNothing);
    },
  );

  testWidgets('media cleanup page starts with no selected items', (
    tester,
  ) async {
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:asset-1',
        syncRootId: 'root-1',
        localPath: 'asset://asset-1',
        relativePath: 'IMG_0001.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 7, 3),
        status: 'cleanup_pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7, 3),
        lastError: '相册资源已备份，等待你确认后再删除本地照片和视频',
        sourceType: 'media_asset',
        assetId: 'asset-1',
        assetMediaType: 'image',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'delete',
              archivePath: '',
            ),
          ]),
          uploadTasks: uploadTasks,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'delete',
              archivePath: '',
              createdAt: '2026-07-03T01:00:00Z',
            ),
          ]),
          mediaGateway: FakeMediaBackupGateway(
            permission: const MediaPermissionStatus(state: 'authorized'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('open_media_cleanup_page_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('待清理照片和视频'), findsOneWidget);
    expect(find.text('当前已选择 0'), findsOneWidget);
    expect(find.text('请选择要清理的项目'), findsOneWidget);
  });

  testWidgets('media cleanup page confirms one selected item', (tester) async {
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:asset-1',
        syncRootId: 'root-1',
        localPath: 'asset://asset-1',
        relativePath: 'IMG_0001.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 7, 3),
        status: 'cleanup_pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7, 3),
        lastError: '相册资源已备份，等待你确认后再删除本地照片和视频',
        sourceType: 'media_asset',
        assetId: 'asset-1',
        assetMediaType: 'image',
      ),
    ]);
    final mediaGateway = FakeMediaBackupGateway(
      permission: const MediaPermissionStatus(state: 'authorized'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'delete',
              archivePath: '',
            ),
          ]),
          uploadTasks: uploadTasks,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'delete',
              archivePath: '',
              createdAt: '2026-07-03T01:00:00Z',
            ),
          ]),
          mediaGateway: mediaGateway,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('open_media_cleanup_page_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('待清理照片和视频'), findsOneWidget);
    expect(find.text('当前已选择 0'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('media_cleanup_select_root-1:asset-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认清理 1 个'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('confirm_media_cleanup_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认删除本机相册资源？'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('confirm_media_cleanup_dialog_button')),
    );
    await tester.pumpAndSettle();

    expect(uploadTasks.saved.single.status, 'deleted_local');
    expect(mediaGateway.deletedAssetIds, ['asset-1']);
    expect(find.text('已清理 1 个，仍待处理 0 个'), findsOneWidget);
  });

  testWidgets(
    'media cleanup page cancels confirmation without deleting asset',
    (tester) async {
      final uploadTasks = FakeUploadTaskStore([
        LocalUploadTask(
          id: 'root-1:asset-1',
          syncRootId: 'root-1',
          localPath: 'asset://asset-1',
          relativePath: 'IMG_0001.jpg',
          sizeBytes: 3,
          modifiedAt: DateTime.utc(2026, 7, 3),
          status: 'cleanup_pending',
          attempts: 0,
          createdAt: DateTime.utc(2026, 7, 3),
          lastError: '相册资源已备份，等待你确认后再删除本地照片和视频',
          sourceType: 'media_asset',
          assetId: 'asset-1',
          assetMediaType: 'image',
        ),
      ]);
      final mediaGateway = FakeMediaBackupGateway(
        permission: const MediaPermissionStatus(state: 'authorized'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SyncHomeScreen(
            storage: FakeSessionStore(
              token: 'server-token',
              deviceId: 'device-1',
            ),
            syncRootMappings: FakeSyncRootMappingStore([
              const LocalSyncRootMapping(
                syncRootId: 'root-1',
                localPath: '',
                encryptedPath: 'media-backup:v1:source-1',
                cleanupPolicy: 'delete',
                archivePath: '',
              ),
            ]),
            uploadTasks: uploadTasks,
            syncRoots: FakeSyncRootGateway([
              const SyncRoot(
                id: 'root-1',
                userId: 'user-1',
                deviceId: 'device-1',
                encryptedPath: 'media-backup:v1:source-1',
                cleanupPolicy: 'delete',
                archivePath: '',
                createdAt: '2026-07-03T01:00:00Z',
              ),
            ]),
            mediaGateway: mediaGateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('open_media_cleanup_page_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('media_cleanup_select_root-1:asset-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm_media_cleanup_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(uploadTasks.saved.single.status, 'cleanup_pending');
      expect(mediaGateway.deletedAssetIds, isEmpty);
    },
  );

  testWidgets('media cleanup page limits selection to ten items', (
    tester,
  ) async {
    LocalUploadTask mediaCleanupTask(int index) {
      final assetId = 'asset-$index';
      return LocalUploadTask(
        id: 'root-1:$assetId',
        syncRootId: 'root-1',
        localPath: 'asset://$assetId',
        relativePath: 'IMG_${index.toString().padLeft(4, '0')}.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 7, 3),
        status: 'cleanup_pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7, 3),
        lastError: '相册资源已备份，等待你确认后再删除本地照片和视频',
        sourceType: 'media_asset',
        assetId: assetId,
        assetMediaType: 'image',
      );
    }

    final uploadTasks = FakeUploadTaskStore([
      for (var index = 1; index <= 11; index++) mediaCleanupTask(index),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'delete',
              archivePath: '',
            ),
          ]),
          uploadTasks: uploadTasks,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'media-backup:v1:source-1',
              cleanupPolicy: 'delete',
              archivePath: '',
              createdAt: '2026-07-03T01:00:00Z',
            ),
          ]),
          mediaGateway: FakeMediaBackupGateway(
            permission: const MediaPermissionStatus(state: 'authorized'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('open_media_cleanup_page_button')),
    );
    await tester.pumpAndSettle();

    for (var index = 1; index <= 11; index++) {
      final key = ValueKey('media_cleanup_select_root-1:asset-$index');
      await tester.ensureVisible(find.byKey(key));
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    expect(find.text('第一版每次最多清理 10 个，请分批处理。'), findsOneWidget);

    await tester.fling(find.byType(ListView), const Offset(0, 1000), 1000);
    await tester.pumpAndSettle();
    expect(find.text('当前已选择 10'), findsOneWidget);
    expect(find.text('确认清理 10 个'), findsOneWidget);
  });

  testWidgets(
    'media cleanup page shows remaining total after cleaning one of multiple items',
    (tester) async {
      LocalUploadTask mediaCleanupTask(String assetId) {
        return LocalUploadTask(
          id: 'root-1:$assetId',
          syncRootId: 'root-1',
          localPath: 'asset://$assetId',
          relativePath: 'IMG_$assetId.jpg',
          sizeBytes: 3,
          modifiedAt: DateTime.utc(2026, 7, 3),
          status: 'cleanup_pending',
          attempts: 0,
          createdAt: DateTime.utc(2026, 7, 3),
          lastError: '相册资源已备份，等待你确认后再删除本地照片和视频',
          sourceType: 'media_asset',
          assetId: assetId,
          assetMediaType: 'image',
        );
      }

      final uploadTasks = FakeUploadTaskStore([
        mediaCleanupTask('asset-1'),
        mediaCleanupTask('asset-2'),
        mediaCleanupTask('asset-3'),
      ]);
      final mediaGateway = FakeMediaBackupGateway(
        permission: const MediaPermissionStatus(state: 'authorized'),
        cleanupResultsByAssetId: const {
          'asset-1': MediaAssetCleanupResult(deleted: true),
          'asset-2': MediaAssetCleanupResult(
            deleted: false,
            message: '系统未允许删除本地相册资源',
          ),
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SyncHomeScreen(
            storage: FakeSessionStore(
              token: 'server-token',
              deviceId: 'device-1',
            ),
            syncRootMappings: FakeSyncRootMappingStore([
              const LocalSyncRootMapping(
                syncRootId: 'root-1',
                localPath: '',
                encryptedPath: 'media-backup:v1:source-1',
                cleanupPolicy: 'delete',
                archivePath: '',
              ),
            ]),
            uploadTasks: uploadTasks,
            syncRoots: FakeSyncRootGateway([
              const SyncRoot(
                id: 'root-1',
                userId: 'user-1',
                deviceId: 'device-1',
                encryptedPath: 'media-backup:v1:source-1',
                cleanupPolicy: 'delete',
                archivePath: '',
                createdAt: '2026-07-03T01:00:00Z',
              ),
            ]),
            mediaGateway: mediaGateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('open_media_cleanup_page_button')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('media_cleanup_select_root-1:asset-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('media_cleanup_select_root-1:asset-2')),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认清理 2 个'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('confirm_media_cleanup_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm_media_cleanup_dialog_button')),
      );
      await tester.pumpAndSettle();

      expect(uploadTasks.saved[0].status, 'deleted_local');
      expect(uploadTasks.saved[1].status, 'cleanup_pending');
      expect(uploadTasks.saved[2].status, 'cleanup_pending');
      expect(find.text('已清理 1 个，仍待处理 2 个'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('media_cleanup_select_root-1:asset-1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('media_cleanup_select_root-1:asset-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('media_cleanup_select_root-1:asset-3')),
        findsOneWidget,
      );
    },
  );

  testWidgets('sync home can upload one sync root from row menu', (
    tester,
  ) async {
    final uploadExecutor = FakeUploadExecutor(uploadedCount: 1);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path-1',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
          uploadExecutor: uploadExecutor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('sync_root_quick_actions_root-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('上传此目录'));
    await tester.pumpAndSettle();

    expect(uploadExecutor.callCount, 1);
    expect(uploadExecutor.syncRootId, 'root-1');
    expect(find.text('已上传此目录 1 个任务'), findsOneWidget);
  });

  testWidgets('sync home pulls remote changes', (tester) async {
    final pullExecutor = FakeRemotePullExecutor(
      result: const SyncPullResult(
        downloadedCount: 2,
        deleteCount: 1,
        blockedDeleteCount: 1,
        nextCursor: 9,
        hasMore: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: FakeSyncRootGateway(const []),
          remotePullExecutor: pullExecutor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pull_remote_changes_button')));
    await tester.pumpAndSettle();

    expect(pullExecutor.callCount, 1);
    expect(find.text('已下载 2 个远端更新，处理 1 个删除，其中 1 个被本地改动保护'), findsOneWidget);
  });

  testWidgets('sync home runs startup auto pull silently', (tester) async {
    final autoSyncStatus = FakeAutoSyncStatusStore();
    final pullExecutor = FakeRemotePullExecutor(
      result: const SyncPullResult(
        downloadedCount: 2,
        deleteCount: 1,
        blockedDeleteCount: 0,
        nextCursor: 9,
        hasMore: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          autoSyncStatus: autoSyncStatus,
          syncRoots: FakeSyncRootGateway(const []),
          remotePullExecutor: pullExecutor,
          autoSyncEnabled: true,
          autoSyncInitialDelay: Duration.zero,
          autoSyncInterval: const Duration(days: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(pullExecutor.callCount, 1);
    expect(autoSyncStatus.saved.status, 'success');
    expect(autoSyncStatus.saved.downloadedCount, 2);
    expect(find.textContaining('已下载 2 个远端更新'), findsNothing);
  });

  testWidgets('sync home periodically scans uploads and pulls', (tester) async {
    final autoSyncStatus = FakeAutoSyncStatusStore();
    final scanner = FakeLocalSyncScanner([
      LocalSyncFile(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 7, 1),
      ),
    ]);
    final uploadExecutor = FakeUploadExecutor(uploadedCount: 1);
    final pullExecutor = FakeRemotePullExecutor(
      result: const SyncPullResult(
        downloadedCount: 1,
        deleteCount: 0,
        blockedDeleteCount: 0,
        nextCursor: 10,
        hasMore: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            const LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: '/Users/alice/Photos',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
            ),
          ]),
          uploadTasks: FakeUploadTaskStore(),
          autoSyncStatus: autoSyncStatus,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
          localScanner: scanner,
          uploadExecutor: uploadExecutor,
          remotePullExecutor: pullExecutor,
          autoSyncEnabled: true,
          autoSyncInitialDelay: const Duration(days: 1),
          autoSyncInterval: const Duration(milliseconds: 10),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(scanner.callCount, 1);
    expect(uploadExecutor.callCount, 1);
    expect(pullExecutor.callCount, 1);
    expect(autoSyncStatus.saved.scannedCount, 1);
    expect(autoSyncStatus.saved.uploadedCount, 1);
    expect(autoSyncStatus.saved.downloadedCount, 1);
  });

  testWidgets('sync home shows local sync issues', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncIssues: FakeSyncIssueStore([
            LocalSyncIssue(
              id: 'remote_delete_blocked:root-1:object-1',
              type: 'remote_delete_blocked',
              syncRootId: 'root-1',
              objectId: 'object-1',
              versionId: 'version-1',
              relativePath: 'photos/a.jpg',
              localPath: '/Users/alice/Photos/a.jpg',
              message: '远端删除被本地改动保护',
              status: 'open',
              createdAt: DateTime.utc(2026, 6, 29),
            ),
          ]),
          syncRoots: FakeSyncRootGateway(const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('待处理问题 1 个'), findsOneWidget);
    expect(find.text('远端删除被本地改动保护'), findsOneWidget);
    expect(find.text('photos/a.jpg'), findsOneWidget);
  });

  testWidgets('sync home marks local sync issue resolved', (tester) async {
    final issueStore = FakeSyncIssueStore([
      LocalSyncIssue(
        id: 'remote_delete_blocked:root-1:object-1',
        type: 'remote_delete_blocked',
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'photos/a.jpg',
        localPath: '/Users/alice/Photos/a.jpg',
        message: '远端删除被本地改动保护',
        status: 'open',
        createdAt: DateTime.utc(2026, 6, 29),
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncIssues: issueStore,
          syncRoots: FakeSyncRootGateway(const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey(
          'resolve_sync_issue_remote_delete_blocked:root-1:object-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(issueStore.issues.single.status, 'resolved');
    expect(find.text('远端删除被本地改动保护'), findsNothing);
  });

  testWidgets('sync status issue detail can resolve conflict issue', (
    tester,
  ) async {
    final paths = await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('vaultsync_conflict_');
      final conflictFile = File('${dir.path}/photos/a conflict.jpg');
      await conflictFile.parent.create(recursive: true);
      await conflictFile.writeAsBytes([1, 2, 3]);
      return (dir: dir, conflictFile: conflictFile);
    });
    final dir = paths!.dir;
    final conflictFile = paths.conflictFile;
    addTearDown(() => dir.delete(recursive: true));
    final issueStore = FakeSyncIssueStore([
      LocalSyncIssue(
        id: 'download_conflict:root-1:object-1',
        type: 'download_conflict',
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'photos/a.jpg',
        localPath: conflictFile.path,
        message: '远端文件与本地改动冲突，已保存冲突副本',
        status: 'open',
        createdAt: DateTime.utc(2026, 6, 29),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore([
            LocalSyncRootMapping(
              syncRootId: 'root-1',
              localPath: dir.path,
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
            ),
          ]),
          uploadTasks: FakeUploadTaskStore(),
          syncIssues: issueStore,
          syncRoots: FakeSyncRootGateway([
            const SyncRoot(
              id: 'root-1',
              userId: 'user-1',
              deviceId: 'device-1',
              encryptedPath: 'base64:path',
              cleanupPolicy: 'keep',
              archivePath: '',
              createdAt: '2026-07-01T00:00:00Z',
            ),
          ]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('open_sync_status_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(
        const ValueKey('sync_issue_download_conflict:root-1:object-1'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('问题详情'), findsOneWidget);
    expect(find.text('下载冲突'), findsWidgets);
    expect(find.text('上传冲突副本'), findsOneWidget);
    expect(find.text('暂不处理，关闭提醒'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('resolve_issue_from_detail_button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(issueStore.issues.single.status, 'resolved');
  });

  testWidgets('sync home updates cleanup policy from management dialog', (
    tester,
  ) async {
    final syncRoots = FakeSyncRootGateway([
      const SyncRoot(
        id: 'root-1',
        userId: 'user-1',
        deviceId: 'device-1',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'keep',
        archivePath: '',
        createdAt: '2026-07-01T00:00:00Z',
      ),
    ]);
    final mappings = FakeSyncRootMappingStore([
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'keep',
        archivePath: '',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: mappings,
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: syncRoots,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('manage_sync_root_root-1')));
    await tester.pumpAndSettle();
    expect(find.text('管理同步目录'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('manage_sync_root_cleanup_policy_field')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('上传后删除本地文件').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('save_managed_sync_root_button')),
    );
    await tester.pumpAndSettle();

    expect(syncRoots.updatedToken, 'server-token');
    expect(syncRoots.updatedSyncRootId, 'root-1');
    expect(syncRoots.updatedCleanupPolicy, 'delete');
    expect(mappings.saved.single.cleanupPolicy, 'delete');
    expect(find.text('清理策略：上传后删除'), findsOneWidget);
  });

  testWidgets(
    'sync home deletes sync root and keeps server content by default',
    (tester) async {
      final syncRoots = FakeSyncRootGateway([
        const SyncRoot(
          id: 'root-1',
          userId: 'user-1',
          deviceId: 'device-1',
          encryptedPath: 'base64:path',
          cleanupPolicy: 'keep',
          archivePath: '',
          createdAt: '2026-07-01T00:00:00Z',
        ),
      ]);
      final mappings = FakeSyncRootMappingStore([
        const LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: '/Users/alice/Photos',
          encryptedPath: 'base64:path',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]);
      final uploadTasks = FakeUploadTaskStore([
        LocalUploadTask(
          id: 'root-1:a.jpg',
          syncRootId: 'root-1',
          localPath: '/Users/alice/Photos/a.jpg',
          relativePath: 'a.jpg',
          sizeBytes: 1,
          modifiedAt: DateTime.utc(2026, 7),
          status: 'pending',
          attempts: 0,
          createdAt: DateTime.utc(2026, 7),
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: SyncHomeScreen(
            storage: FakeSessionStore(
              token: 'server-token',
              deviceId: 'device-1',
            ),
            syncRootMappings: mappings,
            uploadTasks: uploadTasks,
            syncRoots: syncRoots,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('manage_sync_root_root-1')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('delete_managed_sync_root_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('保留服务器上的内容'), findsOneWidget);
      expect(find.text('只会从本机取消同步，不会删除 NAS 上已经上传的文件。'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('confirm_delete_sync_root_button')),
      );
      await tester.pumpAndSettle();

      expect(syncRoots.deletedToken, 'server-token');
      expect(syncRoots.deletedSyncRootId, 'root-1');
      expect(syncRoots.deletedRemote, isFalse);
      expect(mappings.saved, isEmpty);
      expect(uploadTasks.saved, isEmpty);
    },
  );

  testWidgets('sync home can delete sync root with server content', (
    tester,
  ) async {
    final syncRoots = FakeSyncRootGateway([
      const SyncRoot(
        id: 'root-1',
        userId: 'user-1',
        deviceId: 'device-1',
        encryptedPath: 'base64:path',
        cleanupPolicy: 'keep',
        archivePath: '',
        createdAt: '2026-07-01T00:00:00Z',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncHomeScreen(
          storage: FakeSessionStore(
            token: 'server-token',
            deviceId: 'device-1',
          ),
          syncRootMappings: FakeSyncRootMappingStore(),
          uploadTasks: FakeUploadTaskStore(),
          syncRoots: syncRoots,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('manage_sync_root_root-1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('delete_managed_sync_root_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('keep_remote_content_checkbox')),
    );
    await tester.pumpAndSettle();
    expect(find.text('服务器上的该同步目录内容也会被删除，此操作不可恢复。'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('confirm_delete_sync_root_button')),
    );
    await tester.pumpAndSettle();

    expect(syncRoots.deletedRemote, isTrue);
  });
}

class FakeSyncRootGateway implements SyncRootGateway {
  final List<SyncRoot> initialRoots;
  final List<SyncRoot> createdRoots = [];
  String? token;
  String? createdToken;
  String? createdDeviceId;
  String? createdEncryptedPath;
  String? createdCleanupPolicy;
  String? createdArchivePath;
  String? updatedToken;
  String? updatedSyncRootId;
  String? updatedCleanupPolicy;
  String? deletedToken;
  String? deletedSyncRootId;
  bool? deletedRemote;
  int listCallCount = 0;

  FakeSyncRootGateway(this.initialRoots);

  @override
  Future<List<SyncRoot>> listSyncRoots({required String token}) async {
    this.token = token;
    listCallCount += 1;
    return [
      for (final root in initialRoots)
        if (!createdRoots.any((created) => created.id == root.id)) root,
      ...createdRoots,
    ];
  }

  @override
  Future<SyncRoot> createSyncRoot({
    required String token,
    required String deviceId,
    required String encryptedPath,
    required String cleanupPolicy,
    required String archivePath,
  }) async {
    createdToken = token;
    createdDeviceId = deviceId;
    createdEncryptedPath = encryptedPath;
    createdCleanupPolicy = cleanupPolicy;
    createdArchivePath = archivePath;
    final root = SyncRoot(
      id: 'root-1',
      userId: 'user-1',
      deviceId: deviceId,
      encryptedPath: encryptedPath,
      cleanupPolicy: cleanupPolicy,
      archivePath: archivePath,
      createdAt: '2026-06-27T01:00:00Z',
    );
    createdRoots.add(root);
    return root;
  }

  @override
  Future<SyncRoot> updateSyncRootCleanupPolicy({
    required String token,
    required String syncRootId,
    required String cleanupPolicy,
  }) async {
    updatedToken = token;
    updatedSyncRootId = syncRootId;
    updatedCleanupPolicy = cleanupPolicy;
    final allRoots = [...initialRoots, ...createdRoots];
    final existing = allRoots.firstWhere((root) => root.id == syncRootId);
    final updated = SyncRoot(
      id: existing.id,
      userId: existing.userId,
      deviceId: existing.deviceId,
      encryptedPath: existing.encryptedPath,
      cleanupPolicy: cleanupPolicy,
      archivePath: '',
      createdAt: existing.createdAt,
    );
    createdRoots
      ..clear()
      ..add(updated);
    return updated;
  }

  @override
  Future<void> deleteSyncRoot({
    required String token,
    required String syncRootId,
    required bool deleteRemote,
  }) async {
    deletedToken = token;
    deletedSyncRootId = syncRootId;
    deletedRemote = deleteRemote;
    createdRoots.removeWhere((root) => root.id == syncRootId);
  }
}

class ThrowingSyncRootGateway implements SyncRootGateway {
  final Object error;

  const ThrowingSyncRootGateway(this.error);

  @override
  Future<List<SyncRoot>> listSyncRoots({required String token}) async {
    throw error;
  }

  @override
  Future<SyncRoot> createSyncRoot({
    required String token,
    required String deviceId,
    required String encryptedPath,
    required String cleanupPolicy,
    required String archivePath,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SyncRoot> updateSyncRootCleanupPolicy({
    required String token,
    required String syncRootId,
    required String cleanupPolicy,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteSyncRoot({
    required String token,
    required String syncRootId,
    required bool deleteRemote,
  }) async {
    throw UnimplementedError();
  }
}

class FakeSessionStore implements SessionStore {
  final String? token;
  final String? deviceId;

  FakeSessionStore({this.token, this.deviceId});

  @override
  Future<String?> loadAuthToken() async => token;

  @override
  Future<String?> loadAuthExpiresAt() async => '2999-01-01T00:00:00Z';

  @override
  Future<String?> loadDeviceId() async => deviceId;

  @override
  Future<void> saveAuthSession(AuthSession session) async {}

  @override
  Future<void> saveDevice(RegisteredDevice device) async {}
}

class FakeSyncRootMappingStore implements SyncRootMappingStore {
  final List<LocalSyncRootMapping> saved;

  FakeSyncRootMappingStore([List<LocalSyncRootMapping> initial = const []])
    : saved = [...initial];

  @override
  Future<List<LocalSyncRootMapping>> loadSyncRootMappings() async => saved;

  @override
  Future<void> saveSyncRootMapping(LocalSyncRootMapping mapping) async {
    saved
      ..removeWhere((existing) => existing.syncRootId == mapping.syncRootId)
      ..add(mapping);
  }

  @override
  Future<void> saveSyncRootMappings(List<LocalSyncRootMapping> mappings) async {
    saved
      ..clear()
      ..addAll(mappings);
  }
}

class FakeUploadTaskStore implements UploadTaskStore {
  final List<LocalUploadTask> saved;

  FakeUploadTaskStore([List<LocalUploadTask> initial = const []])
    : saved = [...initial];

  @override
  Future<List<LocalUploadTask>> loadUploadTasks() async => saved;

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {
    saved
      ..clear()
      ..addAll(tasks);
  }
}

class FakeMediaBackupSourceStore implements MediaBackupSourceStore {
  final List<LocalMediaBackupSource> saved;

  FakeMediaBackupSourceStore([List<LocalMediaBackupSource> initial = const []])
    : saved = [...initial];

  @override
  Future<List<LocalMediaBackupSource>> loadMediaBackupSources() async => saved;

  @override
  Future<void> saveMediaBackupSources(
    List<LocalMediaBackupSource> sources,
  ) async {
    saved
      ..clear()
      ..addAll(sources);
  }
}

class FakeMediaBackupGateway implements MediaBackupGateway {
  final MediaPermissionStatus permission;
  final List<MediaAssetSnapshot> assets;
  final MediaAssetCleanupResult cleanupResult;
  final Map<String, MediaAssetCleanupResult> cleanupResultsByAssetId;
  final List<String> deletedAssetIds = [];
  int requestCount = 0;

  FakeMediaBackupGateway({
    required this.permission,
    this.assets = const [],
    this.cleanupResult = const MediaAssetCleanupResult(deleted: true),
    this.cleanupResultsByAssetId = const {},
  });

  @override
  Future<MediaPermissionStatus> requestPermission() async {
    requestCount += 1;
    return permission;
  }

  @override
  Future<List<MediaAssetSnapshot>> listAssets(
    LocalMediaBackupSource source,
  ) async {
    return assets;
  }

  @override
  Future<List<int>> readAssetBytes(String assetId) {
    throw UnimplementedError();
  }

  @override
  Future<MediaAssetCleanupResult> deleteAsset(String assetId) async {
    deletedAssetIds.add(assetId);
    return cleanupResultsByAssetId[assetId] ?? cleanupResult;
  }
}

class FakeSyncIssueStore implements SyncIssueStore {
  final List<LocalSyncIssue> issues;

  FakeSyncIssueStore(this.issues);

  @override
  Future<List<LocalSyncIssue>> loadSyncIssues() async => issues;

  @override
  Future<void> saveSyncIssue(LocalSyncIssue issue) async {
    issues.add(issue);
  }

  @override
  Future<void> markSyncIssueResolved({required String issueId}) async {
    final index = issues.indexWhere((issue) => issue.id == issueId);
    final issue = issues[index];
    issues[index] = LocalSyncIssue(
      id: issue.id,
      type: issue.type,
      syncRootId: issue.syncRootId,
      objectId: issue.objectId,
      versionId: issue.versionId,
      relativePath: issue.relativePath,
      localPath: issue.localPath,
      message: issue.message,
      status: 'resolved',
      createdAt: issue.createdAt,
    );
  }
}

class FakeAutoSyncStatusStore implements AutoSyncStatusStore {
  AutoSyncStatus saved;

  FakeAutoSyncStatusStore([this.saved = const AutoSyncStatus()]);

  @override
  Future<AutoSyncStatus> loadAutoSyncStatus() async => saved;

  @override
  Future<void> saveAutoSyncStatus(AutoSyncStatus status) async {
    saved = status;
  }
}

class FakeSyncHistoryStore implements SyncHistoryStore {
  final List<LocalSyncHistoryEntry> entries;

  FakeSyncHistoryStore([List<LocalSyncHistoryEntry> initial = const []])
    : entries = [...initial];

  @override
  Future<List<LocalSyncHistoryEntry>> loadSyncHistory() async {
    return [...entries]
      ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
  }

  @override
  Future<void> addSyncHistory(LocalSyncHistoryEntry entry) async {
    entries.insert(0, entry);
  }

  @override
  Future<void> clearSyncHistory() async {
    entries.clear();
  }
}

class FakeFolderPicker implements FolderPicker {
  final String? path;

  const FakeFolderPicker(this.path);

  @override
  Future<String?> chooseSyncFolder() async => path;
}

class FakeFileAccessPermissionGateway implements FileAccessPermissionGateway {
  var openCount = 0;

  @override
  Future<void> openFileAccessSettings() async {
    openCount += 1;
  }
}

class FakePathProtector implements LocalPathProtector {
  const FakePathProtector();

  @override
  String protectLocalPath(String localPath) => 'protected:$localPath';
}

class FakeLocalSyncScanner implements LocalSyncScanGateway {
  final List<LocalSyncFile> files;
  int callCount = 0;
  String? syncRootId;

  FakeLocalSyncScanner(this.files);

  @override
  Future<List<LocalSyncFile>> scanMappedRoots({String? syncRootId}) async {
    callCount += 1;
    this.syncRootId = syncRootId;
    return files;
  }
}

class FakeUploadExecutor implements LocalUploadExecutionGateway {
  final int uploadedCount;
  final int failedCount;
  int callCount = 0;
  String? syncRootId;

  FakeUploadExecutor({required this.uploadedCount, this.failedCount = 0});

  @override
  Future<UploadExecutionResult> executePendingUploads({
    String? syncRootId,
  }) async {
    callCount += 1;
    this.syncRootId = syncRootId;
    return UploadExecutionResult(
      uploadedCount: uploadedCount,
      failedCount: failedCount,
    );
  }
}

class FakeRemotePullExecutor implements RemoteSyncPullGateway {
  final SyncPullResult result;
  int callCount = 0;

  FakeRemotePullExecutor({required this.result});

  @override
  Future<SyncPullResult> pullRemoteChanges() async {
    callCount += 1;
    return result;
  }
}

class FakeRemoteBackupGateway implements RemoteBackupGateway {
  final List<RemoteBackupObject> objects;
  String? token;
  String? syncRootId;
  int? cursor;
  int? limit;

  FakeRemoteBackupGateway(this.objects);

  @override
  Future<RemoteBackupObjectPage> listRemoteBackupObjects({
    required String token,
    required String syncRootId,
    int cursor = 0,
    int limit = 100,
  }) async {
    this.token = token;
    this.syncRootId = syncRootId;
    this.cursor = cursor;
    this.limit = limit;
    return RemoteBackupObjectPage(
      items: [
        for (final object in objects)
          if (object.syncRootId == syncRootId) object,
      ],
      nextCursor: objects.isEmpty ? cursor : objects.last.cursorValue,
      hasMore: false,
    );
  }
}

class FakeRemoteObjectDeleteGateway implements RemoteObjectDeleteGateway {
  String? token;
  String? deviceId;
  String? syncRootId;
  final List<String> objectIds = [];

  @override
  Future<void> deleteRemoteObject({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
  }) async {
    this.token = token;
    this.deviceId = deviceId;
    this.syncRootId = syncRootId;
    objectIds.add(objectId);
  }
}

class FakeRemoteMetadataDecrypter implements RemoteMetadataDecrypter {
  final Map<String, RemoteBackupEntry> entries;

  const FakeRemoteMetadataDecrypter(this.entries);

  @override
  Future<RemoteBackupEntry> decrypt(RemoteBackupObject object) async {
    return entries[object.objectId] ??
        RemoteBackupEntry(
          syncRootId: object.syncRootId,
          objectId: object.objectId,
          versionId: object.versionId,
          name: '无法解密的备份对象',
          relativePath: '无法解密的备份对象',
          sizeBytes: object.sizeBytes,
          updatedAt: object.updatedAt,
          decryptable: false,
        );
  }
}
