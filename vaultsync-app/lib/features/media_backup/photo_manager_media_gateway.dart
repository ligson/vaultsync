import 'dart:io';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import 'media_backup_gateway.dart';
import 'media_backup_models.dart';

typedef MediaAssetDeleteDelegate =
    Future<List<String>> Function(List<String> assetIds);
typedef MediaAssetExistsDelegate = Future<bool> Function(String assetId);

class PhotoManagerMediaGateway
    implements
        MediaBackupGateway,
        MediaAssetFileResolver,
        MediaAssetThumbnailGateway {
  static const _assetPageSize = 200;
  static const _deleteBatchSize = 500;

  final MediaAssetDeleteDelegate _deleteAssets;
  final MediaAssetExistsDelegate _assetExists;

  const PhotoManagerMediaGateway({
    MediaAssetDeleteDelegate deleteAssets = _deleteAssetsWithPhotoManager,
    MediaAssetExistsDelegate assetExists = _assetExistsWithPhotoManager,
  }) : _deleteAssets = deleteAssets,
       _assetExists = assetExists;

  static Future<List<String>> _deleteAssetsWithPhotoManager(
    List<String> assetIds,
  ) {
    return PhotoManager.editor.deleteWithIds(assetIds);
  }

  static Future<bool> _assetExistsWithPhotoManager(String assetId) async {
    return (await AssetEntity.fromId(assetId)) != null;
  }

  static String assetTypeFor(String mediaTypes) {
    return switch (mediaTypes) {
      'image' => 'image',
      'video' => 'video',
      _ => 'common',
    };
  }

  @override
  Future<MediaPermissionStatus> requestPermission() async {
    final result = await PhotoManager.requestPermissionExtend();
    if (result.isAuth) {
      return const MediaPermissionStatus(state: 'granted');
    }
    if (result.isLimited) {
      return const MediaPermissionStatus(
        state: 'limited',
        message: '当前仅能访问部分照片和视频',
      );
    }
    if (result == PermissionState.restricted) {
      return const MediaPermissionStatus(
        state: 'restricted',
        message: '系统限制了相册访问权限',
      );
    }
    return const MediaPermissionStatus(state: 'denied', message: '未获得相册访问权限');
  }

  @override
  Future<List<MediaAssetSnapshot>> listAssets(
    LocalMediaBackupSource source,
  ) async {
    final paths = await PhotoManager.getAssetPathList(
      type: _requestTypeFor(source.mediaTypes),
    );
    final selectedAlbumIds = source.albumIds.toSet();
    final snapshots = <MediaAssetSnapshot>[];
    for (final path in paths) {
      if (source.albumScope == 'selected' &&
          !selectedAlbumIds.contains(path.id)) {
        continue;
      }
      final count = await path.assetCountAsync;
      for (var start = 0; start < count; start += _assetPageSize) {
        final end = (start + _assetPageSize).clamp(0, count);
        final assets = await path.getAssetListRange(start: start, end: end);
        for (final asset in assets) {
          final file = await asset.file;
          final stat = file == null ? null : await file.stat();
          snapshots.add(
            MediaAssetSnapshot(
              id: asset.id,
              albumId: path.id,
              albumName: path.name,
              mediaType: asset.type == AssetType.video ? 'video' : 'image',
              fileName: asset.title ?? asset.id,
              extension: _extensionFor(asset.title),
              sizeBytes: stat?.size ?? 0,
              createdAt: asset.createDateTime,
              modifiedAt: asset.modifiedDateTime,
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
      }
    }
    return snapshots;
  }

  @override
  Future<List<int>> readAssetBytes(String assetId) async {
    final file = await resolveAssetFile(assetId);
    if (file == null) {
      throw Exception('无法读取该照片或视频');
    }
    return file.readAsBytes();
  }

  @override
  Future<File?> resolveAssetFile(String assetId) async {
    final entity = await AssetEntity.fromId(assetId);
    return entity?.file;
  }

  @override
  Future<Uint8List?> loadThumbnail(
    String assetId, {
    int width = 360,
    int height = 240,
  }) async {
    final entity = await AssetEntity.fromId(assetId);
    if (entity == null) {
      return null;
    }
    return entity.thumbnailDataWithSize(
      ThumbnailSize(width, height),
      quality: 82,
    );
  }

  @override
  Future<MediaAssetCleanupResult> deleteAsset(String assetId) async {
    final result = await deleteAssets([assetId]);
    if (result.deletedAssetIds.contains(assetId)) {
      return const MediaAssetCleanupResult(deleted: true);
    }
    return const MediaAssetCleanupResult(
      deleted: false,
      message: '系统未允许删除本地相册资源',
    );
  }

  @override
  Future<MediaAssetBatchCleanupResult> deleteAssets(
    List<String> assetIds,
  ) async {
    final ids = assetIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      return const MediaAssetBatchCleanupResult();
    }
    final orderedIds = ids.toList(growable: false);
    final deletedIds = <String>{};
    var hadPartialResult = false;
    var skippedMissingCount = 0;
    for (var start = 0; start < orderedIds.length; start += _deleteBatchSize) {
      final end = (start + _deleteBatchSize).clamp(0, orderedIds.length);
      final batch = orderedIds.sublist(start, end);
      final batchNumber = start ~/ _deleteBatchSize + 1;
      final existingBatch = <String>[];
      for (final assetId in batch) {
        bool exists;
        try {
          exists = await _assetExists(assetId);
        } catch (_) {
          exists = false;
        }
        if (exists) {
          existingBatch.add(assetId);
        } else {
          deletedIds.add(assetId);
          skippedMissingCount += 1;
        }
      }
      if (existingBatch.isEmpty) {
        continue;
      }
      List<String> result;
      try {
        result = await _deleteAssets(existingBatch);
      } catch (_) {
        return MediaAssetBatchCleanupResult(
          deletedAssetIds: deletedIds,
          message: deletedIds.isEmpty
              ? '第 $batchNumber 批本地相册资源删除失败，请保持 App 前台并确认系统删除弹窗后重试'
              : '已清理 ${deletedIds.length} 个，第 $batchNumber 批删除失败，剩余项目可稍后重试',
        );
      }

      final batchIds = existingBatch.toSet();
      final deletedInBatch = result.where(batchIds.contains).toSet();
      deletedIds.addAll(deletedInBatch);
      if (deletedInBatch.isEmpty) {
        return MediaAssetBatchCleanupResult(
          deletedAssetIds: deletedIds,
          message: deletedIds.isEmpty
              ? '系统未允许删除本地相册资源'
              : '已清理 ${deletedIds.length} 个，后续批次已取消，剩余项目可稍后重试',
        );
      }
      if (deletedInBatch.length < existingBatch.length) {
        hadPartialResult = true;
      }
    }
    return MediaAssetBatchCleanupResult(
      deletedAssetIds: deletedIds,
      message: hadPartialResult
          ? '部分本地相册资源未被系统删除，可稍后重试'
          : skippedMissingCount > 0
          ? '已跳过 $skippedMissingCount 个本地已不存在的相册资源'
          : '',
    );
  }

  RequestType _requestTypeFor(String mediaTypes) {
    return switch (assetTypeFor(mediaTypes)) {
      'image' => RequestType.image,
      'video' => RequestType.video,
      _ => RequestType.common,
    };
  }

  String _extensionFor(String? title) {
    final value = title ?? '';
    final dotIndex = value.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == value.length - 1) {
      return '';
    }
    return value.substring(dotIndex + 1).toLowerCase();
  }
}
