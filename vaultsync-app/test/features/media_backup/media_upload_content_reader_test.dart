import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_gateway.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_models.dart';
import 'package:vaultsync_app/features/media_backup/media_upload_content_reader.dart';
import 'package:vaultsync_app/features/sync/encrypted_upload_payload_preparer.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('media aware reader reads media asset bytes from gateway', () async {
    final reader = MediaAwareUploadContentReader(
      fileReader: FakeFileReader(),
      media: FakeMediaBackupGateway(),
    );

    final bytes = await reader.read(
      LocalUploadTask(
        id: 'root-1:asset-1',
        syncRootId: 'root-1',
        localPath: '',
        relativePath: '相册/2026/07/a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 7, 3, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7, 3, 10),
        sourceType: 'media_asset',
        assetId: 'asset-1',
        assetMediaType: 'image',
      ),
    );

    expect(bytes, [1, 2, 3]);
  });
}

class FakeFileReader implements UploadContentReader {
  @override
  Future<List<int>> read(LocalUploadTask task) async => [9];
}

class FakeMediaBackupGateway implements MediaBackupGateway {
  @override
  Future<MediaPermissionStatus> requestPermission() async {
    return const MediaPermissionStatus(state: 'granted');
  }

  @override
  Future<List<MediaAssetSnapshot>> listAssets(LocalMediaBackupSource source) {
    throw UnimplementedError();
  }

  @override
  Future<List<int>> readAssetBytes(String assetId) async => [1, 2, 3];

  @override
  Future<MediaAssetCleanupResult> deleteAsset(String assetId) {
    throw UnimplementedError();
  }
}
