import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/app_storage.dart';
import '../media_backup/media_backup_gateway.dart';
import '../sync/sync_models.dart';
import '../sync/remote_metadata_decrypter.dart';
import '../sync/upload_api_service.dart';
import '../sync/upload_key_store.dart';
import 'media_timeline_models.dart';

abstract interface class MediaTimelineGateway {
  Future<MediaTimelineOverview> loadOverview({
    String mediaType = '',
    String deviceId = '',
  });

  Future<MediaTimelinePage> loadItems({
    required MediaTimelineMonth month,
    String mediaType = '',
    String deviceId = '',
    String cursor = '',
    int limit = 60,
  });

  Future<Uint8List?> loadThumbnail(MediaTimelineEntry entry);
}

abstract interface class MediaTimelineBackfillGateway {
  Future<int> backfillHistory();
}

class MediaTimelineApiService
    implements MediaTimelineGateway, MediaTimelineBackfillGateway {
  final ApiClient apiClient;
  final SessionStore sessionStore;
  final UploadKeyStore keyStore;
  final UploadTaskStore? uploadTasks;
  final MediaAssetThumbnailGateway? localThumbnails;
  Future<Map<String, LocalUploadTask>>? _historicalTasksByVersion;
  Future<int>? _backfillInFlight;
  Future<UploadKeyMaterial>? _keysFuture;
  Future<RemoteMetadataDecrypter>? _metadataDecrypterFuture;

  MediaTimelineApiService({
    required this.apiClient,
    required this.sessionStore,
    required this.keyStore,
    this.uploadTasks,
    this.localThumbnails,
  });

  @override
  Future<MediaTimelineOverview> loadOverview({
    String mediaType = '',
    String deviceId = '',
  }) async {
    final data = await apiClient.get(
      _path('/api/v1/media/months', mediaType: mediaType, deviceId: deviceId),
      token: await _token(),
    );
    final months = (data['items'] as List<Object?>? ?? const [])
        .map((item) => Map<String, Object?>.from(item! as Map))
        .map(
          (item) => MediaTimelineMonthSummary(
            month: MediaTimelineMonth(
              item['year'] as int,
              item['month'] as int,
            ),
            count: item['count'] as int,
          ),
        )
        .toList(growable: false);
    final devices = (data['devices'] as List<Object?>? ?? const [])
        .map((item) => Map<String, Object?>.from(item! as Map))
        .map(
          (item) => MediaTimelineDevice(
            id: item['id'] as String,
            name: item['name'] as String? ?? '未命名设备',
          ),
        )
        .toList(growable: false);
    return MediaTimelineOverview(months: months, devices: devices);
  }

  @override
  Future<MediaTimelinePage> loadItems({
    required MediaTimelineMonth month,
    String mediaType = '',
    String deviceId = '',
    String cursor = '',
    int limit = 60,
  }) async {
    final query = <String, String>{
      'year': '${month.year}',
      'month': '${month.month}',
      'limit': '$limit',
      if (mediaType.isNotEmpty) 'type': mediaType,
      if (deviceId.isNotEmpty) 'device_id': deviceId,
      if (cursor.isNotEmpty) 'cursor': cursor,
    };
    final data = await apiClient.get(
      Uri(path: '/api/v1/media/items', queryParameters: query).toString(),
      token: await _token(),
    );
    final items = await Future.wait([
      for (final item in data['items'] as List<Object?>? ?? const [])
        _entry(Map<String, Object?>.from(item! as Map)),
    ]);
    return MediaTimelinePage(
      items: items,
      nextCursor: data['next_cursor'] as String? ?? '',
      hasMore: data['has_more'] as bool? ?? false,
    );
  }

  @override
  Future<Uint8List?> loadThumbnail(MediaTimelineEntry entry) async {
    final backup = entry.remoteBackup;
    if (backup == null) return null;
    if (entry.hasThumbnail) {
      try {
        final encrypted = await apiClient.getBytes(
          '/api/v1/media/${entry.id}/thumbnail',
          token: await _token(),
        );
        final keys = await _keys();
        return Uint8List.fromList(
          await MediaThumbnailCrypto.decrypt(
            encrypted,
            contentKeyBytes: keys.contentKeyBytes,
            mediaId: entry.id,
            versionId: backup.versionId,
          ),
        );
      } catch (_) {
        // A stale or damaged cache can be regenerated from the local asset.
      }
    }
    final thumbnailGateway = localThumbnails;
    if (thumbnailGateway == null) return null;
    final tasks = await (_historicalTasksByVersion ??=
        _loadHistoricalTasksByVersion());
    final task = tasks[backup.versionId];
    if (task == null || task.assetId.isEmpty) return null;
    final thumbnail = await thumbnailGateway.loadThumbnail(
      task.assetId,
      width: 480,
      height: 480,
    );
    if (thumbnail == null || thumbnail.isEmpty) return null;
    final keys = await _keys();
    final encrypted = await MediaThumbnailCrypto.encrypt(
      thumbnail,
      contentKeyBytes: keys.contentKeyBytes,
      mediaId: entry.id,
      versionId: backup.versionId,
    );
    try {
      await apiClient.putBytes(
        '/api/v1/media/${entry.id}/thumbnail',
        token: await _token(),
        bytes: encrypted,
      );
    } catch (_) {
      // The local thumbnail is still useful for this view; retry on next open.
    }
    return thumbnail;
  }

  Future<Map<String, LocalUploadTask>> _loadHistoricalTasksByVersion() async {
    final store = uploadTasks;
    if (store == null) return const {};
    return {
      for (final task in await store.loadUploadTasks())
        if (task.sourceType == 'media_asset')
          versionIdForUploadTask(task): task,
    };
  }

  @override
  Future<int> backfillHistory() => _backfillInFlight ??= _backfillHistoryOnce();

  Future<int> _backfillHistoryOnce() async {
    const pageSize = 200;
    final store = uploadTasks;
    final tasks = store == null
        ? const <LocalUploadTask>[]
        : (await store.loadUploadTasks())
              .where(
                (task) =>
                    task.sourceType == 'media_asset' &&
                    (task.assetMediaType == 'image' ||
                        task.assetMediaType == 'video') &&
                    (task.status == 'uploaded' ||
                        task.status == 'cleanup_pending' ||
                        task.status == 'deleted_local'),
              )
              .toList(growable: false);

    var indexed = 0;
    var candidateCursor = 0;
    var candidateHasMore = true;

    // Keep reading until the first media item is found. A media root can also
    // contain non-media files, and the empty state must not flash before that.
    while (indexed == 0 && candidateHasMore) {
      final page = await _loadMediaCandidates(
        cursor: candidateCursor,
        limit: pageSize,
      );
      indexed += await _indexRemoteCandidates(page.items);
      candidateCursor = page.nextCursor;
      candidateHasMore = page.hasMore && page.items.isNotEmpty;
    }

    var localStart = 0;
    if (indexed == 0 && tasks.isNotEmpty) {
      final end = (pageSize).clamp(0, tasks.length);
      indexed += await _indexTasks(tasks.sublist(localStart, end));
      localStart = end;
    }

    unawaited(
      _backfillRemaining(
        tasks: tasks,
        localStart: localStart,
        candidateCursor: candidateCursor,
        candidateHasMore: candidateHasMore,
        pageSize: pageSize,
      ),
    );
    return indexed;
  }

  Future<void> _backfillRemaining({
    required List<LocalUploadTask> tasks,
    required int localStart,
    required int candidateCursor,
    required bool candidateHasMore,
    required int pageSize,
  }) async {
    try {
      var cursor = candidateCursor;
      var hasMore = candidateHasMore;
      while (hasMore) {
        final page = await _loadMediaCandidates(
          cursor: cursor,
          limit: pageSize,
        );
        await _indexRemoteCandidates(page.items);
        cursor = page.nextCursor;
        hasMore = page.hasMore && page.items.isNotEmpty;
      }

      for (var start = localStart; start < tasks.length; start += pageSize) {
        final end = (start + pageSize).clamp(0, tasks.length);
        await _indexTasks(tasks.sublist(start, end));
      }
    } catch (_) {
      // A later open resumes from the server's still-unindexed candidates.
    }
  }

  Future<RemoteBackupObjectPage> _loadMediaCandidates({
    required int cursor,
    required int limit,
  }) async {
    final query = <String, String>{'cursor': '$cursor', 'limit': '$limit'};
    final data = await apiClient.get(
      Uri(path: '/api/v1/media/candidates', queryParameters: query).toString(),
      token: await _token(),
    );
    return RemoteBackupObjectPage.fromJson(data);
  }

  Future<int> _indexRemoteCandidates(List<RemoteBackupObject> objects) async {
    final items = <Map<String, Object?>>[];
    for (final object in objects) {
      final item = await _mediaIndexForCandidate(object);
      if (item != null) items.add(item);
    }
    return _postIndexes(items);
  }

  Future<Map<String, Object?>?> _mediaIndexForCandidate(
    RemoteBackupObject object,
  ) async {
    final backup = await (await _metadataDecrypter()).decrypt(object);
    if (!backup.decryptable) return null;
    final mediaType = _mediaTypeForPath(backup.relativePath, backup.name);
    if (mediaType == null) return null;
    final capturedAt = _capturedAtForPath(
      backup.relativePath,
      object.updatedAt,
    );
    return {
      'sync_root_id': object.syncRootId,
      'object_id': object.objectId,
      'version_id': object.versionId,
      'media_type': mediaType,
      'captured_at': capturedAt.toIso8601String(),
      'captured_year': capturedAt.year,
      'captured_month': capturedAt.month,
      'width': 0,
      'height': 0,
      'duration_ms': 0,
    };
  }

  Future<int> _indexTasks(List<LocalUploadTask> tasks) async {
    return _postIndexes([
      for (final task in tasks)
        {
          'sync_root_id': task.syncRootId,
          'object_id': objectIdForUploadTask(task),
          'version_id': versionIdForUploadTask(task),
          'media_type': task.assetMediaType,
          'captured_at': _historicalCapturedAt(task).toIso8601String(),
          'captured_year': _historicalYearMonth(task).$1,
          'captured_month': _historicalYearMonth(task).$2,
          'width': 0,
          'height': 0,
          'duration_ms': 0,
        },
    ]);
  }

  Future<int> _postIndexes(List<Map<String, Object?>> items) async {
    if (items.isEmpty) return 0;
    final data = await apiClient.post(
      '/api/v1/media/indexes',
      token: await _token(),
      body: {'items': items},
    );
    return data['indexed_count'] as int? ?? 0;
  }

  String? _mediaTypeForPath(String relativePath, String name) {
    final value = (relativePath.isNotEmpty ? relativePath : name)
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase();
    final dot = value.lastIndexOf('.');
    if (dot < 0) return null;
    const images = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'heif',
      'avif',
      'bmp',
      'tif',
      'tiff',
      'dng',
      'raw',
    };
    const videos = {
      'mp4',
      'mov',
      'm4v',
      'avi',
      'mkv',
      'webm',
      '3gp',
      'mts',
      'm2ts',
    };
    final extension = value.substring(dot + 1);
    if (images.contains(extension)) return 'image';
    if (videos.contains(extension)) return 'video';
    return null;
  }

  DateTime _capturedAtForPath(String relativePath, String fallback) {
    final modified =
        DateTime.tryParse(fallback)?.toUtc() ?? DateTime.now().toUtc();
    final match = RegExp(
      r'(?:^|/)(\d{4})/(\d{1,2})(?:/|$)',
    ).firstMatch(relativePath.replaceAll('\\', '/'));
    if (match == null) return modified;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    if (year < 1970 || month < 1 || month > 12) return modified;
    final day = modified.year == year && modified.month == month
        ? modified.day
        : 1;
    return DateTime.utc(
      year,
      month,
      day,
      modified.hour,
      modified.minute,
      modified.second,
      modified.millisecond,
      modified.microsecond,
    );
  }

  DateTime _historicalCapturedAt(LocalUploadTask task) {
    final captured = task.capturedAt;
    if (captured != null) return captured.toUtc();
    final parts = task.relativePath.replaceAll('\\', '/').split('/');
    for (var index = 0; index + 1 < parts.length; index += 1) {
      final year = int.tryParse(parts[index]);
      final month = int.tryParse(parts[index + 1]);
      if (year == null || month == null || month < 1 || month > 12) continue;
      final modified = task.modifiedAt.toUtc();
      final day = modified.year == year && modified.month == month
          ? modified.day
          : 1;
      return DateTime.utc(year, month, day, modified.hour, modified.minute);
    }
    return task.modifiedAt.toUtc();
  }

  (int, int) _historicalYearMonth(LocalUploadTask task) {
    final parts = task.relativePath.replaceAll('\\', '/').split('/');
    for (var index = 0; index + 1 < parts.length; index += 1) {
      final year = int.tryParse(parts[index]);
      final month = int.tryParse(parts[index + 1]);
      if (year != null &&
          year >= 1970 &&
          month != null &&
          month >= 1 &&
          month <= 12) {
        return (year, month);
      }
    }
    final captured = (task.capturedAt ?? task.modifiedAt).toLocal();
    return (captured.year, captured.month);
  }

  Future<MediaTimelineEntry> _entry(Map<String, Object?> item) async {
    final mediaType = item['media_type'] as String;
    final object = RemoteBackupObject(
      cursorValue: 0,
      syncRootId: item['sync_root_id'] as String,
      objectId: item['object_id'] as String,
      versionId: item['version_id'] as String,
      sizeBytes: item['size_bytes'] as int,
      updatedAt: item['captured_at'] as String,
      encryptedName: item['encrypted_name'] as String,
      metadataJson: item['metadata_json'] as String,
      contentHash: item['content_hash'] as String,
    );
    final decrypted = await (await _metadataDecrypter()).decrypt(object);
    final backup = decrypted.withPayloadMetadata(
      encryptedName: object.encryptedName,
      metadataJson: object.metadataJson,
    );
    return MediaTimelineEntry(
      id: item['id'] as String,
      deviceId: item['device_id'] as String,
      deviceName: item['device_name'] as String? ?? '未命名设备',
      syncRootId: item['sync_root_id'] as String,
      name: backup.name,
      relativePath: backup.relativePath,
      capturedAt: DateTime.parse(item['captured_at'] as String),
      mediaType: mediaType,
      hasThumbnail: item['has_thumbnail'] as bool? ?? false,
      remoteBackup: backup,
    );
  }

  String _path(
    String path, {
    required String mediaType,
    required String deviceId,
  }) {
    return Uri(
      path: path,
      queryParameters: {
        if (mediaType.isNotEmpty) 'type': mediaType,
        if (deviceId.isNotEmpty) 'device_id': deviceId,
      },
    ).toString();
  }

  Future<String> _token() async {
    final token = await sessionStore.loadAuthToken();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效，请重新登录');
    }
    return token;
  }

  Future<UploadKeyMaterial> _keys() {
    return _keysFuture ??= keyStore.loadUploadKeys();
  }

  Future<RemoteMetadataDecrypter> _metadataDecrypter() {
    return _metadataDecrypterFuture ??= _keys().then(
      (keys) => XChaCha20RemoteMetadataDecrypter(
        metadataKeyBytes: keys.metadataKeyBytes,
      ),
    );
  }
}

abstract interface class MediaPostUploadThumbnailPublisher {
  Future<void> publish({
    required String token,
    required LocalUploadTask task,
    required String mediaId,
    required String versionId,
  });
}

class EncryptedMediaThumbnailPublisher
    implements MediaPostUploadThumbnailPublisher {
  final MediaAssetThumbnailGateway thumbnails;
  final UploadKeyStore keyStore;
  final MediaThumbnailUploadGateway uploads;

  const EncryptedMediaThumbnailPublisher({
    required this.thumbnails,
    required this.keyStore,
    required this.uploads,
  });

  @override
  Future<void> publish({
    required String token,
    required LocalUploadTask task,
    required String mediaId,
    required String versionId,
  }) async {
    if (task.sourceType != 'media_asset' || task.assetId.isEmpty) return;
    final thumbnail = await thumbnails.loadThumbnail(
      task.assetId,
      width: 480,
      height: 480,
    );
    if (thumbnail == null || thumbnail.isEmpty) return;
    final keys = await keyStore.loadUploadKeys();
    final encrypted = await MediaThumbnailCrypto.encrypt(
      thumbnail,
      contentKeyBytes: keys.contentKeyBytes,
      mediaId: mediaId,
      versionId: versionId,
    );
    await uploads.uploadMediaThumbnail(
      token: token,
      mediaId: mediaId,
      bytes: encrypted,
    );
  }
}

class MediaThumbnailCrypto {
  static const _magic = 'VSTH001';
  static const _algorithmId = 1;
  static const _nonceLength = 24;

  static Future<List<int>> encrypt(
    List<int> bytes, {
    required List<int> contentKeyBytes,
    required String mediaId,
    required String versionId,
  }) async {
    final cipher = Xchacha20.poly1305Aead();
    final nonce = cipher.newNonce();
    final box = await cipher.encrypt(
      bytes,
      secretKey: SecretKey(contentKeyBytes),
      nonce: nonce,
      aad: _aad(mediaId, versionId),
    );
    return [
      ..._magic.codeUnits,
      _algorithmId,
      nonce.length,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
  }

  static Future<List<int>> decrypt(
    List<int> bytes, {
    required List<int> contentKeyBytes,
    required String mediaId,
    required String versionId,
  }) async {
    if (bytes.length <= _magic.length + 2 + _nonceLength + 16 ||
        String.fromCharCodes(bytes.take(_magic.length)) != _magic ||
        bytes[_magic.length] != _algorithmId ||
        bytes[_magic.length + 1] != _nonceLength) {
      throw Exception('缩略图密文格式无效');
    }
    final nonceStart = _magic.length + 2;
    final cipherStart = nonceStart + _nonceLength;
    final macStart = bytes.length - 16;
    final cipher = Xchacha20.poly1305Aead();
    return cipher.decrypt(
      SecretBox(
        bytes.sublist(cipherStart, macStart),
        nonce: bytes.sublist(nonceStart, cipherStart),
        mac: Mac(bytes.sublist(macStart)),
      ),
      secretKey: SecretKey(contentKeyBytes),
      aad: _aad(mediaId, versionId),
    );
  }

  static List<int> _aad(String mediaId, String versionId) =>
      utf8.encode('vaultsync/v1/media-thumbnail|$mediaId|$versionId');
}
