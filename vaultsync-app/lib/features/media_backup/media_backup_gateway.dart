import 'dart:io';
import 'dart:typed_data';

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

class MediaAssetBatchCleanupResult {
  final Set<String> deletedAssetIds;
  final String message;

  const MediaAssetBatchCleanupResult({
    this.deletedAssetIds = const <String>{},
    this.message = '',
  });
}

class MissingMediaAssetException implements Exception {
  final String assetId;

  const MissingMediaAssetException(this.assetId);

  @override
  String toString() => '无法读取该照片或视频';
}

abstract interface class MediaAssetCleaner {
  Future<MediaAssetCleanupResult> deleteAsset(String assetId);

  Future<MediaAssetBatchCleanupResult> deleteAssets(List<String> assetIds);
}

abstract interface class MediaAssetFileResolver {
  Future<File?> resolveAssetFile(String assetId);
}

abstract interface class MediaAssetThumbnailGateway {
  Future<Uint8List?> loadThumbnail(
    String assetId, {
    int width = 360,
    int height = 240,
  });
}

abstract interface class MediaBackupGateway implements MediaAssetCleaner {
  Future<MediaPermissionStatus> requestPermission();

  Future<List<MediaAssetSnapshot>> listAssets(LocalMediaBackupSource source);

  Future<List<int>> readAssetBytes(String assetId);

  @override
  Future<MediaAssetCleanupResult> deleteAsset(String assetId);

  @override
  Future<MediaAssetBatchCleanupResult> deleteAssets(List<String> assetIds);
}
