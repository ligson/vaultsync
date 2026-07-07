import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_gateway.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_models.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_scanner.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('media backup scanner creates upload tasks for new assets', () async {
    final store = FakeUploadTaskStore();
    final scanner = MediaBackupScanner(
      media: FakeMediaBackupGateway([
        MediaAssetSnapshot(
          id: 'asset-1',
          albumId: 'album-1',
          albumName: '相机胶卷',
          mediaType: 'image',
          fileName: 'IMG_0001.JPG',
          extension: 'jpg',
          sizeBytes: 10,
          createdAt: DateTime.utc(2026, 7, 3, 8),
          modifiedAt: DateTime.utc(2026, 7, 3, 9),
        ),
      ]),
      uploadTasks: store,
    );

    final result = await scanner.scan(
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
        createdAt: DateTime.utc(2026, 7, 3, 8),
        updatedAt: DateTime.utc(2026, 7, 3, 8),
      ),
    );

    expect(result.scannedCount, 1);
    expect(result.createdTaskCount, 1);
    expect(store.tasks.single.sourceType, 'media_asset');
    expect(store.tasks.single.assetId, 'asset-1');
    expect(store.tasks.single.relativePath, '相机胶卷/2026/07/IMG_0001.JPG');
  });
}

class FakeMediaBackupGateway implements MediaBackupGateway {
  final List<MediaAssetSnapshot> assets;

  FakeMediaBackupGateway(this.assets);

  @override
  Future<MediaPermissionStatus> requestPermission() async {
    return const MediaPermissionStatus(state: 'granted');
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
  Future<MediaAssetCleanupResult> deleteAsset(String assetId) {
    throw UnimplementedError();
  }
}

class FakeUploadTaskStore implements UploadTaskStore {
  List<LocalUploadTask> tasks = [];

  @override
  Future<List<LocalUploadTask>> loadUploadTasks() async => tasks;

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {
    this.tasks = tasks;
  }
}
