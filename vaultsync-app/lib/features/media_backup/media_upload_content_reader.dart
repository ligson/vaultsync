import '../sync/encrypted_upload_payload_preparer.dart';
import '../sync/sync_models.dart';
import 'media_backup_gateway.dart';

class MediaAwareUploadContentReader implements UploadContentReader {
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
}
