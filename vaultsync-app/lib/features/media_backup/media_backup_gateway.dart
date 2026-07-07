import 'media_backup_models.dart';

class MediaPermissionStatus {
  final String state;
  final String message;

  const MediaPermissionStatus({required this.state, this.message = ''});
}

class MediaAssetCleanupResult {
  final bool deleted;
  final String message;

  const MediaAssetCleanupResult({required this.deleted, this.message = ''});
}

abstract interface class MediaAssetCleaner {
  Future<MediaAssetCleanupResult> deleteAsset(String assetId);
}

abstract interface class MediaBackupGateway implements MediaAssetCleaner {
  Future<MediaPermissionStatus> requestPermission();

  Future<List<MediaAssetSnapshot>> listAssets(LocalMediaBackupSource source);

  Future<List<int>> readAssetBytes(String assetId);

  @override
  Future<MediaAssetCleanupResult> deleteAsset(String assetId);
}
