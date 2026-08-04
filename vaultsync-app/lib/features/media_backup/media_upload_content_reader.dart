import 'dart:io';

import '../sync/encrypted_upload_payload_preparer.dart';
import '../sync/sync_models.dart';
import 'media_backup_gateway.dart';

class MediaAwareUploadContentReader implements StreamingUploadContentReader {
  final UploadContentReader fileReader;
  final MediaBackupGateway media;

  const MediaAwareUploadContentReader({
    required this.fileReader,
    required this.media,
  });

  @override
  Future<List<int>> read(LocalUploadTask task) {
    if (task.sourceType == 'media_asset') {
      return media.readAssetBytes(task.assetId);
    }
    return fileReader.read(task);
  }

  @override
  Future<File?> resolveFile(LocalUploadTask task) {
    if (task.sourceType == 'media_asset') {
      final gateway = media;
      if (gateway is MediaAssetFileResolver) {
        return (gateway as MediaAssetFileResolver).resolveAssetFile(
          task.assetId,
        );
      }
      return Future.value(null);
    }
    final reader = fileReader;
    if (reader is StreamingUploadContentReader) {
      return reader.resolveFile(task);
    }
    return Future.value(null);
  }
}
