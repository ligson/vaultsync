import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import 'media_backup_gateway.dart';
import 'media_backup_models.dart';

class PhotoManagerMediaGateway
    implements MediaBackupGateway, MediaAssetFileResolver {
  static const _assetPageSize = 200;

  const PhotoManagerMediaGateway();

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
  Future<MediaAssetCleanupResult> deleteAsset(String assetId) async {
    final result = await PhotoManager.editor.deleteWithIds([assetId]);
    if (result.isNotEmpty) {
      return const MediaAssetCleanupResult(deleted: true);
    }
    return const MediaAssetCleanupResult(
      deleted: false,
      message: '系统未允许删除本地相册资源',
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
