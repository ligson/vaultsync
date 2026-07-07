import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/local_cleanup_executor.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test(
    'cleanup marks uploaded keep task clean without touching file',
    () async {
      final dir = await Directory.systemTemp.createTemp('vaultsync_cleanup_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.jpg');
      await file.writeAsString('abc');
      final modifiedAt = await file.lastModified();
      final uploadTasks = FakeUploadTaskStore([
        _uploadedTask(file.path, modifiedAt: modifiedAt),
      ]);

      final executor = LocalCleanupExecutor(
        mappings: FakeSyncRootMappingStore(
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
        uploadTasks: uploadTasks,
      );

      final result = await executor.cleanupUploadedTasks();

      expect(result.cleanedCount, 1);
      expect(await file.exists(), isTrue);
      expect(uploadTasks.saved.single.status, 'clean');
    },
  );

  test('cleanup deletes uploaded task when policy is delete', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_cleanup_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.jpg');
    await file.writeAsString('abc');
    final modifiedAt = await file.lastModified();
    final uploadTasks = FakeUploadTaskStore([
      _uploadedTask(file.path, modifiedAt: modifiedAt),
    ]);

    final executor = LocalCleanupExecutor(
      mappings: FakeSyncRootMappingStore(
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
      uploadTasks: uploadTasks,
    );

    final result = await executor.cleanupUploadedTasks();

    expect(result.cleanedCount, 1);
    expect(await file.exists(), isFalse);
    expect(uploadTasks.saved.single.status, 'deleted_local');
  });

  test(
    'cleanup archives uploaded task without overwriting existing file',
    () async {
      final dir = await Directory.systemTemp.createTemp('vaultsync_cleanup_');
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/source/a.jpg');
      await source.parent.create(recursive: true);
      await source.writeAsString('abc');
      final archiveDir = Directory('${dir.path}/archive');
      await File('${archiveDir.path}/a.jpg').create(recursive: true);
      await File('${archiveDir.path}/a.jpg').writeAsString('existing');
      final modifiedAt = await source.lastModified();
      final uploadTasks = FakeUploadTaskStore([
        _uploadedTask(source.path, modifiedAt: modifiedAt),
      ]);

      final executor = LocalCleanupExecutor(
        mappings: FakeSyncRootMappingStore(
          cleanupPolicy: 'archive',
          archivePath: archiveDir.path,
        ),
        uploadTasks: uploadTasks,
      );

      final result = await executor.cleanupUploadedTasks();

      expect(result.cleanedCount, 1);
      expect(await source.exists(), isFalse);
      expect(await File('${archiveDir.path}/a.jpg').readAsString(), 'existing');
      expect(await File('${archiveDir.path}/a-1.jpg').readAsString(), 'abc');
      expect(uploadTasks.saved.single.status, 'archived');
    },
  );

  test('cleanup keeps changed local file and marks cleanup pending', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_cleanup_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.jpg');
    await file.writeAsString('abc');
    final modifiedAt = await file.lastModified();
    await file.writeAsString('changed');
    final uploadTasks = FakeUploadTaskStore([
      _uploadedTask(file.path, modifiedAt: modifiedAt),
    ]);

    final executor = LocalCleanupExecutor(
      mappings: FakeSyncRootMappingStore(
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
      uploadTasks: uploadTasks,
    );

    final result = await executor.cleanupUploadedTasks();

    expect(result.cleanedCount, 0);
    expect(result.pendingCount, 1);
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), 'changed');
    expect(uploadTasks.saved.single.status, 'cleanup_pending');
    expect(uploadTasks.saved.single.lastError, '本地文件已变化，暂不自动删除，请确认后重试');
  });

  test('cleanup retries cleanup pending task', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_cleanup_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.jpg');
    await file.writeAsString('abc');
    final modifiedAt = await file.lastModified();
    final uploadTasks = FakeUploadTaskStore([
      _uploadedTask(
        file.path,
        modifiedAt: modifiedAt,
        status: 'cleanup_pending',
        lastError: '上次清理失败',
      ),
    ]);

    final executor = LocalCleanupExecutor(
      mappings: FakeSyncRootMappingStore(
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
      uploadTasks: uploadTasks,
    );

    final result = await executor.cleanupUploadedTasks();

    expect(result.cleanedCount, 1);
    expect(result.pendingCount, 0);
    expect(await file.exists(), isFalse);
    expect(uploadTasks.saved.single.status, 'deleted_local');
    expect(uploadTasks.saved.single.lastError, '');
  });

  test(
    'cleanup keeps uploaded media asset pending until user confirms',
    () async {
      final uploadTasks = FakeUploadTaskStore([
        LocalUploadTask(
          id: 'root-1:asset-1',
          syncRootId: 'root-1',
          localPath: '',
          relativePath: '相册/2026/07/a.jpg',
          sizeBytes: 3,
          modifiedAt: DateTime.utc(2026, 7, 3, 9),
          status: 'uploaded',
          attempts: 0,
          createdAt: DateTime.utc(2026, 7, 3, 10),
          sourceType: 'media_asset',
          assetId: 'asset-1',
          assetMediaType: 'image',
        ),
      ]);
      final cleaner = FakeMediaAssetCleaner(deleted: true);
      final executor = LocalCleanupExecutor(
        mappings: FakeSyncRootMappingStore(
          cleanupPolicy: 'delete',
          archivePath: '',
        ),
        uploadTasks: uploadTasks,
        mediaCleaner: cleaner,
      );

      final result = await executor.cleanupUploadedTasks();

      expect(result.cleanedCount, 0);
      expect(result.pendingCount, 1);
      expect(cleaner.deletedAssetIds, isEmpty);
      expect(uploadTasks.saved.single.status, 'cleanup_pending');
      expect(uploadTasks.saved.single.lastError, '相册资源已备份，等待你确认后再删除本地照片和视频');
    },
  );

  test('cleanupTask retries one cleanup pending task only', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_cleanup_');
    addTearDown(() => dir.delete(recursive: true));
    final first = File('${dir.path}/a.jpg');
    final second = File('${dir.path}/b.jpg');
    await first.writeAsString('abc');
    await second.writeAsString('abc');
    final firstModifiedAt = await first.lastModified();
    final secondModifiedAt = await second.lastModified();
    final uploadTasks = FakeUploadTaskStore([
      _uploadedTask(
        first.path,
        id: 'root-1:a.jpg',
        relativePath: 'a.jpg',
        modifiedAt: firstModifiedAt,
        status: 'cleanup_pending',
        lastError: '上次清理失败',
      ),
      _uploadedTask(
        second.path,
        id: 'root-1:b.jpg',
        relativePath: 'b.jpg',
        modifiedAt: secondModifiedAt,
        status: 'cleanup_pending',
        lastError: '仍待处理',
      ),
    ]);

    final executor = LocalCleanupExecutor(
      mappings: FakeSyncRootMappingStore(
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
      uploadTasks: uploadTasks,
    );

    final result = await executor.cleanupTask('root-1:a.jpg');

    expect(result.cleanedCount, 1);
    expect(result.pendingCount, 0);
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isTrue);
    expect(uploadTasks.saved[0].status, 'deleted_local');
    expect(uploadTasks.saved[1].status, 'cleanup_pending');
  });

  test('ignoreCleanupTask marks one cleanup pending task ignored', () async {
    final uploadTasks = FakeUploadTaskStore([
      _uploadedTask(
        '/local/root/a.jpg',
        modifiedAt: DateTime.utc(2026, 6, 27),
        status: 'cleanup_pending',
        lastError: '上次清理失败',
      ),
    ]);
    final executor = LocalCleanupExecutor(
      mappings: FakeSyncRootMappingStore(
        cleanupPolicy: 'delete',
        archivePath: '',
      ),
      uploadTasks: uploadTasks,
    );

    await executor.ignoreCleanupTask('root-1:a.jpg');

    expect(uploadTasks.saved.single.status, 'cleanup_ignored');
    expect(uploadTasks.saved.single.lastError, '已忽略本次本地清理提醒');
  });

  test(
    'confirmMediaCleanupTasks deletes one pending media asset after user confirmation',
    () async {
      final uploadTasks = FakeUploadTaskStore([
        _mediaTask(
          id: 'root-1:asset-1',
          assetId: 'asset-1',
          status: 'cleanup_pending',
          lastError: '相册资源已备份，等待你确认后再删除本地照片和视频',
          uploadSessionId: 'session-1',
          uploadPayloadHash: 'payload-hash-1',
          uploadTotalSize: 1024,
          uploadChunkSize: 256,
          uploadedBytes: 1024,
        ),
      ]);
      final cleaner = FakeMediaAssetCleaner(deleted: true);
      final executor = LocalCleanupExecutor(
        mappings: FakeSyncRootMappingStore(
          cleanupPolicy: 'delete',
          archivePath: '',
        ),
        uploadTasks: uploadTasks,
        mediaCleaner: cleaner,
      );

      final result = await executor.confirmMediaCleanupTasks([
        'root-1:asset-1',
      ]);

      expect(result.cleanedCount, 1);
      expect(result.pendingCount, 0);
      expect(cleaner.deletedAssetIds, ['asset-1']);
      expect(uploadTasks.saved.single.status, 'deleted_local');
      expect(uploadTasks.saved.single.lastError, '');
      expect(uploadTasks.saved.single.uploadSessionId, 'session-1');
      expect(uploadTasks.saved.single.uploadPayloadHash, 'payload-hash-1');
      expect(uploadTasks.saved.single.uploadTotalSize, 1024);
      expect(uploadTasks.saved.single.uploadChunkSize, 256);
      expect(uploadTasks.saved.single.uploadedBytes, 1024);
      expect(uploadTasks.saved.single.sourceType, 'media_asset');
      expect(uploadTasks.saved.single.assetId, 'asset-1');
      expect(uploadTasks.saved.single.assetMediaType, 'image');
    },
  );

  test(
    'confirmMediaCleanupTasks keeps media task pending when system refuses deletion',
    () async {
      final uploadTasks = FakeUploadTaskStore([
        _mediaTask(
          id: 'root-1:asset-1',
          assetId: 'asset-1',
          status: 'cleanup_pending',
          lastError: '等待确认',
          uploadSessionId: 'session-2',
          uploadPayloadHash: 'payload-hash-2',
          uploadTotalSize: 2048,
          uploadChunkSize: 512,
          uploadedBytes: 2048,
        ),
      ]);
      final cleaner = FakeMediaAssetCleaner(deleted: false);
      final executor = LocalCleanupExecutor(
        mappings: FakeSyncRootMappingStore(
          cleanupPolicy: 'delete',
          archivePath: '',
        ),
        uploadTasks: uploadTasks,
        mediaCleaner: cleaner,
      );

      final result = await executor.confirmMediaCleanupTasks([
        'root-1:asset-1',
      ]);

      expect(result.cleanedCount, 0);
      expect(result.pendingCount, 1);
      expect(cleaner.deletedAssetIds, ['asset-1']);
      expect(uploadTasks.saved.single.status, 'cleanup_pending');
      expect(uploadTasks.saved.single.lastError, '系统未允许删除本地相册资源');
      expect(uploadTasks.saved.single.uploadSessionId, 'session-2');
      expect(uploadTasks.saved.single.uploadPayloadHash, 'payload-hash-2');
      expect(uploadTasks.saved.single.uploadTotalSize, 2048);
      expect(uploadTasks.saved.single.uploadChunkSize, 512);
      expect(uploadTasks.saved.single.uploadedBytes, 2048);
      expect(uploadTasks.saved.single.sourceType, 'media_asset');
      expect(uploadTasks.saved.single.assetId, 'asset-1');
      expect(uploadTasks.saved.single.assetMediaType, 'image');
    },
  );

  test(
    'confirmMediaCleanupTasks keeps media task pending when cleaner throws',
    () async {
      final uploadTasks = FakeUploadTaskStore([
        _mediaTask(
          id: 'root-1:asset-1',
          assetId: 'asset-1',
          status: 'cleanup_pending',
          lastError: '等待确认',
        ),
      ]);
      final cleaner = FakeMediaAssetCleaner(deleted: false, throws: true);
      final executor = LocalCleanupExecutor(
        mappings: FakeSyncRootMappingStore(
          cleanupPolicy: 'delete',
          archivePath: '',
        ),
        uploadTasks: uploadTasks,
        mediaCleaner: cleaner,
      );

      final result = await executor.confirmMediaCleanupTasks([
        'root-1:asset-1',
      ]);

      expect(result.cleanedCount, 0);
      expect(result.pendingCount, 1);
      expect(cleaner.deletedAssetIds, ['asset-1']);
      expect(uploadTasks.saved.single.status, 'cleanup_pending');
      expect(uploadTasks.saved.single.lastError, '删除本地相册资源失败，请检查相册权限后重试');
    },
  );

  test(
    'confirmMediaCleanupTasks ignores non media and non pending tasks',
    () async {
      final uploadTasks = FakeUploadTaskStore([
        _uploadedTask(
          '/local/root/a.jpg',
          id: 'root-1:file-1',
          relativePath: 'a.jpg',
          modifiedAt: DateTime.utc(2026, 7, 3, 9),
          status: 'cleanup_pending',
          lastError: '普通文件待清理',
        ),
        _mediaTask(
          id: 'root-1:asset-1',
          assetId: 'asset-1',
          status: 'uploaded',
          lastError: '',
        ),
      ]);
      final cleaner = FakeMediaAssetCleaner(deleted: true);
      final executor = LocalCleanupExecutor(
        mappings: FakeSyncRootMappingStore(
          cleanupPolicy: 'delete',
          archivePath: '',
        ),
        uploadTasks: uploadTasks,
        mediaCleaner: cleaner,
      );

      final result = await executor.confirmMediaCleanupTasks([
        'root-1:file-1',
        'root-1:asset-1',
      ]);

      expect(result.cleanedCount, 0);
      expect(result.pendingCount, 0);
      expect(cleaner.deletedAssetIds, isEmpty);
      expect(uploadTasks.saved[0].status, 'cleanup_pending');
      expect(uploadTasks.saved[0].lastError, '普通文件待清理');
      expect(uploadTasks.saved[1].status, 'uploaded');
      expect(uploadTasks.saved[1].lastError, '');
    },
  );

  test(
    'confirmMediaCleanupTasks keeps task pending when cleanup policy changed',
    () async {
      final uploadTasks = FakeUploadTaskStore([
        _mediaTask(
          id: 'root-1:asset-1',
          assetId: 'asset-1',
          status: 'cleanup_pending',
          lastError: '等待确认',
        ),
      ]);
      final cleaner = FakeMediaAssetCleaner(deleted: true);
      final executor = LocalCleanupExecutor(
        mappings: FakeSyncRootMappingStore(
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
        uploadTasks: uploadTasks,
        mediaCleaner: cleaner,
      );

      final result = await executor.confirmMediaCleanupTasks([
        'root-1:asset-1',
      ]);

      expect(result.cleanedCount, 0);
      expect(result.pendingCount, 1);
      expect(cleaner.deletedAssetIds, isEmpty);
      expect(uploadTasks.saved.single.status, 'cleanup_pending');
      expect(uploadTasks.saved.single.lastError, '清理策略已变更，请重新确认是否删除本机相册资源');
    },
  );
}

LocalUploadTask _uploadedTask(
  String localPath, {
  String id = 'root-1:a.jpg',
  String relativePath = 'a.jpg',
  required DateTime modifiedAt,
  String status = 'uploaded',
  String lastError = '',
}) {
  return LocalUploadTask(
    id: id,
    syncRootId: 'root-1',
    localPath: localPath,
    relativePath: relativePath,
    sizeBytes: 3,
    modifiedAt: modifiedAt,
    status: status,
    attempts: 0,
    createdAt: DateTime.utc(2026, 6, 27, 10),
    lastError: lastError,
  );
}

LocalUploadTask _mediaTask({
  required String id,
  required String assetId,
  required String status,
  String lastError = '',
  String uploadSessionId = '',
  String uploadPayloadHash = '',
  int uploadTotalSize = 0,
  int uploadChunkSize = 0,
  int uploadedBytes = 0,
}) {
  return LocalUploadTask(
    id: id,
    syncRootId: 'root-1',
    localPath: '',
    relativePath: '相册/2026/07/a.jpg',
    sizeBytes: 3,
    modifiedAt: DateTime.utc(2026, 7, 3, 9),
    status: status,
    attempts: 0,
    createdAt: DateTime.utc(2026, 7, 3, 10),
    lastError: lastError,
    uploadSessionId: uploadSessionId,
    uploadPayloadHash: uploadPayloadHash,
    uploadTotalSize: uploadTotalSize,
    uploadChunkSize: uploadChunkSize,
    uploadedBytes: uploadedBytes,
    sourceType: 'media_asset',
    assetId: assetId,
    assetMediaType: 'image',
  );
}

class FakeSyncRootMappingStore implements SyncRootMappingStore {
  final String cleanupPolicy;
  final String archivePath;

  const FakeSyncRootMappingStore({
    required this.cleanupPolicy,
    required this.archivePath,
  });

  @override
  Future<List<LocalSyncRootMapping>> loadSyncRootMappings() async {
    return [
      LocalSyncRootMapping(
        syncRootId: 'root-1',
        localPath: '/local/root',
        encryptedPath: 'vaultsync-path:v1:root',
        cleanupPolicy: cleanupPolicy,
        archivePath: archivePath,
      ),
    ];
  }

  @override
  Future<void> saveSyncRootMapping(LocalSyncRootMapping mapping) async {}

  @override
  Future<void> saveSyncRootMappings(
    List<LocalSyncRootMapping> mappings,
  ) async {}
}

class FakeUploadTaskStore implements UploadTaskStore {
  List<LocalUploadTask> saved;

  FakeUploadTaskStore(this.saved);

  @override
  Future<List<LocalUploadTask>> loadUploadTasks() async => saved;

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {
    saved = tasks;
  }
}

class FakeMediaAssetCleaner implements MediaAssetCleaner {
  final bool deleted;
  final bool throws;
  final List<String> deletedAssetIds = [];

  FakeMediaAssetCleaner({required this.deleted, this.throws = false});

  @override
  Future<MediaAssetCleanupResult> deleteAsset(String assetId) async {
    deletedAssetIds.add(assetId);
    if (throws) {
      throw Exception('delete failed');
    }
    return MediaAssetCleanupResult(deleted: deleted);
  }
}
