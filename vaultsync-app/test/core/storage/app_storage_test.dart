import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/auth/auth_models.dart';
import 'package:vaultsync_app/features/device/device_models.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_models.dart';
import 'package:vaultsync_app/features/sync/password_upload_key_deriver.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/upload_key_store.dart';

void main() {
  test('AppStorage saves server address', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    expect(await storage.loadServerAddress(), isNull);

    await storage.saveServerAddress('http://192.168.1.10:8080');

    expect(await storage.loadServerAddress(), 'http://192.168.1.10:8080');
  });

  test('AppStorage saves auth token and registered device id', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveAuthSession(
      const AuthSession(
        token: 'server-token',
        tokenId: 'token-1',
        userId: 'user-1',
        expiresAt: '2026-06-28T00:00:00Z',
      ),
    );
    await storage.saveDevice(
      const RegisteredDevice(
        id: 'device-1',
        userId: 'user-1',
        name: 'Alice iPhone',
        platform: 'ios',
        createdAt: '2026-06-27T00:00:00Z',
      ),
    );

    expect(await storage.loadAuthToken(), 'server-token');
    expect(await storage.loadAuthExpiresAt(), '2026-06-28T00:00:00Z');
    expect(await storage.loadDeviceId(), 'device-1');
  });

  test('AppStorage clears local user session data', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage(
      uploadKeyDeriver: PasswordUploadKeyDeriver(
        memoryBlocks: 64,
        iterations: 1,
      ),
    );
    await storage.saveAuthSession(
      const AuthSession(
        token: 'server-token',
        tokenId: 'token-1',
        userId: 'user-1',
        expiresAt: '2026-06-28T00:00:00Z',
      ),
    );
    await storage.saveDevice(
      const RegisteredDevice(
        id: 'device-1',
        userId: 'user-1',
        name: 'Alice iPhone',
        platform: 'ios',
        createdAt: '2026-06-27T00:00:00Z',
      ),
    );
    await storage.deriveAndSaveUploadKeys(
      email: 'alice@example.com',
      password: 'password',
    );
    await storage.saveSyncRootMapping(
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos',
        encryptedPath: 'vaultsync-path:v1:abc',
        cleanupPolicy: 'keep',
        archivePath: '',
      ),
    );

    await storage.clearLocalSession();

    expect(await storage.loadAuthToken(), isNull);
    expect(await storage.loadAuthExpiresAt(), isNull);
    expect(await storage.loadDeviceId(), isNull);
    expect(storage.loadUploadKeys(), throwsA(isA<MissingUploadKeyException>()));
    expect(await storage.loadSyncRootMappings(), hasLength(1));
    expect(
      (await storage.loadSyncRootMappings()).single.localPath,
      '/Users/alice/Photos',
    );
  });

  test('AppStorage saves local sync root mappings', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveSyncRootMapping(
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos',
        encryptedPath: 'vaultsync-path:v1:abc',
        cleanupPolicy: 'keep',
        archivePath: '',
      ),
    );

    final mappings = await storage.loadSyncRootMappings();

    expect(mappings, hasLength(1));
    expect(mappings.single.syncRootId, 'root-1');
    expect(mappings.single.localPath, '/Users/alice/Photos');
    expect(mappings.single.encryptedPath, 'vaultsync-path:v1:abc');
    expect(mappings.single.cleanupPolicy, 'keep');
  });

  test('AppStorage replaces all local sync root mappings', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveSyncRootMapping(
      const LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/tmp/a',
        encryptedPath: 'path-a',
        cleanupPolicy: 'keep',
        archivePath: '',
      ),
    );
    await storage.saveSyncRootMappings([
      const LocalSyncRootMapping(
        syncRootId: 'root-2',
        localPath: '/tmp/b',
        encryptedPath: 'path-b',
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
    ]);

    final mappings = await storage.loadSyncRootMappings();

    expect(mappings, hasLength(1));
    expect(mappings.single.syncRootId, 'root-2');
    expect(mappings.single.cleanupPolicy, 'delete');
  });

  test('AppStorage saves local upload tasks', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveUploadTasks([
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
    ]);

    final tasks = await storage.loadUploadTasks();

    expect(tasks, hasLength(1));
    expect(tasks.single.id, 'root-1:a.jpg');
    expect(tasks.single.status, 'pending');
    expect(tasks.single.localPath, '/Users/alice/Photos/a.jpg');
  });

  test('AppStorage saves media backup sources', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveMediaBackupSources([
      LocalMediaBackupSource(
        id: 'media-source-1',
        syncRootId: 'root-1',
        name: '相册备份',
        mediaTypes: 'image_video',
        albumScope: 'all',
        albumIds: const [],
        cleanupPolicy: 'delete',
        wifiOnly: true,
        autoBackupEnabled: true,
        createdAt: DateTime.utc(2026, 7, 3, 8),
        updatedAt: DateTime.utc(2026, 7, 3, 9),
      ),
    ]);

    final sources = await storage.loadMediaBackupSources();

    expect(sources, hasLength(1));
    expect(sources.single.syncRootId, 'root-1');
    expect(sources.single.mediaTypes, 'image_video');
    expect(sources.single.cleanupPolicy, 'delete');
    expect(sources.single.wifiOnly, isTrue);
  });

  test('AppStorage preserves media upload task source fields', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveUploadTasks([
      LocalUploadTask(
        id: 'root-1:asset-1',
        syncRootId: 'root-1',
        localPath: '',
        relativePath: '相册/2026/07/a.jpg',
        sizeBytes: 10,
        modifiedAt: DateTime.utc(2026, 7, 3, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7, 3, 10),
        sourceType: 'media_asset',
        assetId: 'asset-1',
        assetMediaType: 'image',
      ),
    ]);

    final task = (await storage.loadUploadTasks()).single;

    expect(task.sourceType, 'media_asset');
    expect(task.assetId, 'asset-1');
    expect(task.assetMediaType, 'image');
  });

  test('AppStorage saves and clears local sync history', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.addSyncHistory(
      LocalSyncHistoryEntry(
        id: 'history-1',
        type: 'scan',
        result: 'success',
        title: '扫描本地文件',
        message: '发现 1 个本地文件',
        syncRootId: 'root-1',
        relativePath: 'a.jpg',
        createdAt: DateTime.utc(2026, 7, 2, 9),
      ),
    );
    await storage.addSyncHistory(
      LocalSyncHistoryEntry(
        id: 'history-2',
        type: 'upload',
        result: 'success',
        title: '上传待处理任务',
        message: '已上传 1 个任务',
        createdAt: DateTime.utc(2026, 7, 2, 10),
      ),
    );

    final items = await storage.loadSyncHistory();

    expect(items.map((item) => item.id), ['history-2', 'history-1']);
    expect(items.first.title, '上传待处理任务');

    await storage.clearSyncHistory();

    expect(await storage.loadSyncHistory(), isEmpty);
  });

  test('AppStorage requires upload encryption keys before sync', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    expect(storage.loadUploadKeys(), throwsA(isA<MissingUploadKeyException>()));
  });

  test(
    'AppStorage derives and reuses password upload encryption keys',
    () async {
      SharedPreferences.setMockInitialValues({});
      const storage = AppStorage(
        uploadKeyDeriver: PasswordUploadKeyDeriver(
          memoryBlocks: 64,
          iterations: 1,
        ),
      );

      final first = await storage.deriveAndSaveUploadKeys(
        email: ' Alice@Example.com ',
        password: 'passw0rd!',
      );
      final second = await storage.loadUploadKeys();

      expect(first.contentKeyBytes, hasLength(uploadKeyLength));
      expect(first.metadataKeyBytes, hasLength(uploadKeyLength));
      expect(second.contentKeyBytes, first.contentKeyBytes);
      expect(second.metadataKeyBytes, first.metadataKeyBytes);
    },
  );

  test('AppStorage overwrites password-derived upload keys on login', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage(
      uploadKeyDeriver: PasswordUploadKeyDeriver(
        memoryBlocks: 64,
        iterations: 1,
      ),
    );

    final first = await storage.deriveAndSaveUploadKeys(
      email: 'alice@example.com',
      password: 'old-password',
    );
    final second = await storage.deriveAndSaveUploadKeys(
      email: 'alice@example.com',
      password: 'new-password',
    );
    final loaded = await storage.loadUploadKeys();

    expect(second.contentKeyBytes, isNot(first.contentKeyBytes));
    expect(second.metadataKeyBytes, isNot(first.metadataKeyBytes));
    expect(loaded.contentKeyBytes, second.contentKeyBytes);
    expect(loaded.metadataKeyBytes, second.metadataKeyBytes);
  });

  test('AppStorage saves remote sync cursor', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    expect(await storage.loadRemoteCursor(), 0);

    await storage.saveRemoteCursor(42);

    expect(await storage.loadRemoteCursor(), 42);
  });

  test('AppStorage saves auto sync status', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveAutoSyncStatus(
      AutoSyncStatus(
        lastStartedAt: DateTime.utc(2026, 7, 1, 9),
        lastFinishedAt: DateTime.utc(2026, 7, 1, 9, 1),
        lastSuccessAt: DateTime.utc(2026, 7, 1, 9, 1),
        status: 'success',
        message: '自动同步完成',
        scannedCount: 3,
        uploadedCount: 2,
        downloadedCount: 1,
      ),
    );

    final status = await storage.loadAutoSyncStatus();

    expect(status.status, 'success');
    expect(status.message, '自动同步完成');
    expect(status.scannedCount, 3);
    expect(status.uploadedCount, 2);
    expect(status.downloadedCount, 1);
    expect(status.lastSuccessAt, DateTime.utc(2026, 7, 1, 9, 1));
  });

  test('AppStorage saves remote version index entries', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveRemoteVersionIndex(
      const LocalRemoteVersionIndex(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'photos/a.jpg',
        localPath: '/local/photos/a.jpg',
        contentHash: 'hash-1',
      ),
    );

    final entries = await storage.loadRemoteVersionIndexes();

    expect(entries, hasLength(1));
    expect(entries.single.objectId, 'object-1');
    expect(entries.single.versionId, 'version-1');
    expect(entries.single.contentHash, 'hash-1');
  });

  test('AppStorage removes remote version index entries', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveRemoteVersionIndex(
      const LocalRemoteVersionIndex(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'photos/a.jpg',
        localPath: '/local/photos/a.jpg',
        contentHash: 'hash-1',
      ),
    );
    await storage.removeRemoteVersionIndex(
      syncRootId: 'root-1',
      objectId: 'object-1',
    );

    expect(await storage.loadRemoteVersionIndexes(), isEmpty);
  });

  test('AppStorage saves local sync issues', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveSyncIssue(
      LocalSyncIssue(
        id: 'download_conflict:root-1:object-1',
        type: 'download_conflict',
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'photos/a.jpg',
        localPath: '/local/photos/a conflict.jpg',
        message: '远端更新已保存为冲突副本',
        status: 'open',
        createdAt: DateTime.utc(2026, 6, 29),
      ),
    );

    final issues = await storage.loadSyncIssues();

    expect(issues, hasLength(1));
    expect(issues.single.type, 'download_conflict');
    expect(issues.single.status, 'open');
  });

  test('AppStorage marks local sync issue resolved', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = AppStorage();

    await storage.saveSyncIssue(
      LocalSyncIssue(
        id: 'remote_delete_blocked:root-1:object-1',
        type: 'remote_delete_blocked',
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'photos/a.jpg',
        localPath: '/local/photos/a.jpg',
        message: '远端删除被本地改动保护',
        status: 'open',
        createdAt: DateTime.utc(2026, 6, 29),
      ),
    );
    await storage.markSyncIssueResolved(
      issueId: 'remote_delete_blocked:root-1:object-1',
    );

    final issues = await storage.loadSyncIssues();

    expect(issues.single.status, 'resolved');
  });
}
