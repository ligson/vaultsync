import '../../core/storage/app_storage.dart';
import '../sync/sync_models.dart';
import 'media_backup_gateway.dart';
import 'media_backup_models.dart';

class MediaBackupScanResult {
  final int scannedCount;
  final int createdTaskCount;

  const MediaBackupScanResult({
    required this.scannedCount,
    required this.createdTaskCount,
  });
}

class MediaBackupScanner {
  final MediaBackupGateway media;
  final UploadTaskStore uploadTasks;

  const MediaBackupScanner({required this.media, required this.uploadTasks});

  Future<MediaBackupScanResult> scan(LocalMediaBackupSource source) async {
    final permission = await media.requestPermission();
    if (permission.state != 'granted' && permission.state != 'limited') {
      throw Exception(
        permission.message.isEmpty ? '未获得相册访问权限' : permission.message,
      );
    }

    final assets = await media.listAssets(source);
    final existingTasks = await uploadTasks.loadUploadTasks();
    final existingIds = existingTasks.map((task) => task.id).toSet();
    final createdTasks = <LocalUploadTask>[];

    for (final asset in assets) {
      final taskId = '${source.syncRootId}:${asset.id}';
      if (existingIds.contains(taskId)) {
        continue;
      }
      createdTasks.add(
        LocalUploadTask(
          id: taskId,
          syncRootId: source.syncRootId,
          localPath: '',
          relativePath: _relativePath(asset),
          sizeBytes: asset.sizeBytes,
          modifiedAt: asset.modifiedAt.toUtc(),
          status: 'pending',
          attempts: 0,
          createdAt: DateTime.now().toUtc(),
          sourceType: 'media_asset',
          assetId: asset.id,
          assetMediaType: asset.mediaType,
        ),
      );
    }

    await uploadTasks.saveUploadTasks([...existingTasks, ...createdTasks]);
    return MediaBackupScanResult(
      scannedCount: assets.length,
      createdTaskCount: createdTasks.length,
    );
  }

  String _relativePath(MediaAssetSnapshot asset) {
    final date = asset.createdAt.toUtc();
    final month = date.month.toString().padLeft(2, '0');
    final fileName = asset.fileName.isEmpty
        ? '${asset.id}.${asset.extension}'
        : asset.fileName;
    return '${asset.albumName}/${date.year}/$month/$fileName';
  }
}
