import 'dart:async';

import '../../core/network/api_client.dart';
import '../../core/storage/app_storage.dart';
import '../sync/remote_metadata_decrypter.dart';
import '../sync/sync_models.dart';
import '../sync/sync_root_display_name_protector.dart';
import '../sync/upload_key_store.dart';
import 'document_center_models.dart';

abstract interface class DocumentCenterGateway {
  Future<DocumentCenterOverview> loadOverview();

  Future<DocumentCenterPage> loadItems({
    String documentType = '',
    String deviceId = '',
    DocumentCenterSort sort = DocumentCenterSort.time,
    DocumentCenterOrder order = DocumentCenterOrder.descending,
    int cursor = 0,
    int limit = 60,
  });
}

abstract interface class DocumentCenterBackfillGateway {
  Future<int> backfillHistory();
}

class DocumentCenterApiService
    implements DocumentCenterGateway, DocumentCenterBackfillGateway {
  final ApiClient apiClient;
  final SessionStore sessionStore;
  final UploadKeyStore keyStore;
  Future<UploadKeyMaterial>? _keysFuture;
  Future<RemoteMetadataDecrypter>? _metadataDecrypterFuture;
  Future<int>? _backfillInFlight;

  DocumentCenterApiService({
    required this.apiClient,
    required this.sessionStore,
    required this.keyStore,
  });

  @override
  Future<DocumentCenterOverview> loadOverview() async {
    final data = await apiClient.get(
      '/api/v1/documents/overview',
      token: await _token(),
    );
    return DocumentCenterOverview(
      devices: [
        for (final raw in data['devices'] as List<Object?>? ?? const [])
          _device(Map<String, Object?>.from(raw! as Map)),
      ],
    );
  }

  DocumentCenterDevice _device(Map<String, Object?> item) =>
      DocumentCenterDevice(
        id: item['id'] as String,
        name: item['name'] as String? ?? '未命名设备',
      );

  @override
  Future<DocumentCenterPage> loadItems({
    String documentType = '',
    String deviceId = '',
    DocumentCenterSort sort = DocumentCenterSort.time,
    DocumentCenterOrder order = DocumentCenterOrder.descending,
    int cursor = 0,
    int limit = 60,
  }) async {
    if (sort == DocumentCenterSort.name) {
      if (cursor > 0) {
        return const DocumentCenterPage(
          items: [],
          nextCursor: 0,
          hasMore: false,
        );
      }
      return _loadAllSortedByName(
        documentType: documentType,
        deviceId: deviceId,
        order: order,
      );
    }
    return _loadRemotePage(
      documentType: documentType,
      deviceId: deviceId,
      sort: sort,
      order: order,
      cursor: cursor,
      limit: limit,
    );
  }

  Future<DocumentCenterPage> _loadAllSortedByName({
    required String documentType,
    required String deviceId,
    required DocumentCenterOrder order,
  }) async {
    final items = <DocumentCenterEntry>[];
    var cursor = 0;
    var hasMore = true;
    while (hasMore) {
      final page = await _loadRemotePage(
        documentType: documentType,
        deviceId: deviceId,
        sort: DocumentCenterSort.time,
        order: DocumentCenterOrder.descending,
        cursor: cursor,
        limit: 200,
      );
      items.addAll(page.items);
      cursor = page.nextCursor;
      hasMore = page.hasMore;
    }
    items.sort((left, right) {
      final result = left.name.toLowerCase().compareTo(
        right.name.toLowerCase(),
      );
      final resolved = result == 0
          ? left.relativePath.compareTo(right.relativePath)
          : result;
      return order == DocumentCenterOrder.ascending ? resolved : -resolved;
    });
    return DocumentCenterPage(
      items: items,
      nextCursor: items.length,
      hasMore: false,
    );
  }

  Future<DocumentCenterPage> _loadRemotePage({
    required String documentType,
    required String deviceId,
    required DocumentCenterSort sort,
    required DocumentCenterOrder order,
    required int cursor,
    required int limit,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'cursor': '$cursor',
      'sort': sort.name,
      'order': order == DocumentCenterOrder.ascending ? 'asc' : 'desc',
      if (documentType.isNotEmpty) 'type': documentType,
      if (deviceId.isNotEmpty) 'device_id': deviceId,
    };
    final data = await apiClient.get(
      Uri(path: '/api/v1/documents/items', queryParameters: query).toString(),
      token: await _token(),
    );
    final items = await Future.wait([
      for (final raw in data['items'] as List<Object?>? ?? const [])
        _entry(Map<String, Object?>.from(raw! as Map)),
    ]);
    return DocumentCenterPage(
      items: items,
      nextCursor: (data['next_cursor'] as num?)?.toInt() ?? cursor,
      hasMore: data['has_more'] as bool? ?? false,
    );
  }

  @override
  Future<int> backfillHistory() => _backfillInFlight ??= _backfillHistoryOnce();

  Future<int> _backfillHistoryOnce() async {
    const pageSize = 200;
    var indexed = 0;
    var cursor = 0;
    var hasMore = true;
    while (indexed == 0 && hasMore) {
      final page = await _loadCandidates(cursor: cursor, limit: pageSize);
      indexed += await _indexCandidates(page.items);
      cursor = page.nextCursor;
      hasMore = page.hasMore && page.items.isNotEmpty;
    }
    if (hasMore) {
      unawaited(_continueBackfill(cursor: cursor, pageSize: pageSize));
    }
    return indexed;
  }

  Future<void> _continueBackfill({
    required int cursor,
    required int pageSize,
  }) async {
    try {
      var nextCursor = cursor;
      var hasMore = true;
      while (hasMore) {
        final page = await _loadCandidates(cursor: nextCursor, limit: pageSize);
        await _indexCandidates(page.items);
        nextCursor = page.nextCursor;
        hasMore = page.hasMore && page.items.isNotEmpty;
      }
    } catch (_) {
      // The next open resumes from candidates that have not been marked yet.
    }
  }

  Future<RemoteBackupObjectPage> _loadCandidates({
    required int cursor,
    required int limit,
  }) async {
    final data = await apiClient.get(
      Uri(
        path: '/api/v1/documents/candidates',
        queryParameters: {'cursor': '$cursor', 'limit': '$limit'},
      ).toString(),
      token: await _token(),
    );
    return RemoteBackupObjectPage.fromJson(data);
  }

  Future<int> _indexCandidates(List<RemoteBackupObject> objects) async {
    final items = <Map<String, Object?>>[];
    final ignoredVersionIds = <String>[];
    for (final object in objects) {
      final backup = await (await _metadataDecrypter()).decrypt(object);
      if (!backup.decryptable) {
        // A corrupt or unsupported metadata payload should not be retried on
        // every document-center open.
        ignoredVersionIds.add(object.versionId);
        continue;
      }
      final classification = documentClassificationForPath(
        backup.relativePath.isNotEmpty ? backup.relativePath : backup.name,
      );
      if (classification == null) {
        ignoredVersionIds.add(object.versionId);
        continue;
      }
      items.add({
        'sync_root_id': object.syncRootId,
        'object_id': object.objectId,
        'version_id': object.versionId,
        'document_type': classification.type,
        'document_format': classification.format,
        'updated_at': object.updatedAt,
      });
    }
    if (items.isEmpty && ignoredVersionIds.isEmpty) return 0;
    final data = await apiClient.post(
      '/api/v1/documents/indexes',
      token: await _token(),
      body: {'items': items, 'ignored_version_ids': ignoredVersionIds},
    );
    return (data['indexed_count'] as num?)?.toInt() ?? 0;
  }

  Future<DocumentCenterEntry> _entry(Map<String, Object?> item) async {
    final object = RemoteBackupObject(
      cursorValue: 0,
      syncRootId: item['sync_root_id'] as String,
      objectId: item['object_id'] as String,
      versionId: item['version_id'] as String,
      encryptedName: item['encrypted_name'] as String,
      contentHash: item['content_hash'] as String,
      sizeBytes: (item['size_bytes'] as num).toInt(),
      metadataJson: item['metadata_json'] as String,
      updatedAt: item['updated_at'] as String,
    );
    final decrypted = await (await _metadataDecrypter()).decrypt(object);
    final backup = decrypted.withPayloadMetadata(
      encryptedName: object.encryptedName,
      metadataJson: object.metadataJson,
    );
    final keys = await _keys();
    final rootName = await SyncRootDisplayNameProtector().decrypt(
      encryptedDisplayName:
          item['encrypted_root_display_name'] as String? ?? '',
      encryptedPath: item['encrypted_root_path'] as String? ?? '',
      keyBytes: keys.metadataKeyBytes,
    );
    return DocumentCenterEntry(
      id: item['id'] as String,
      deviceId: item['device_id'] as String,
      deviceName: item['device_name'] as String? ?? '未命名设备',
      syncRootId: object.syncRootId,
      rootName: rootName ?? '同步目录 ${_shortId(object.syncRootId)}',
      name: backup.name,
      relativePath: backup.relativePath,
      documentType: item['document_type'] as String,
      documentFormat: item['document_format'] as String,
      sizeBytes: object.sizeBytes,
      updatedAt: DateTime.parse(object.updatedAt),
      remoteBackup: backup,
    );
  }

  Future<String> _token() async {
    final token = await sessionStore.loadAuthToken();
    if (token == null || token.isEmpty) throw Exception('登录状态已失效');
    return token;
  }

  Future<UploadKeyMaterial> _keys() =>
      _keysFuture ??= keyStore.loadUploadKeys();

  Future<RemoteMetadataDecrypter> _metadataDecrypter() async =>
      _metadataDecrypterFuture ??= Future.value(
        XChaCha20RemoteMetadataDecrypter(
          metadataKeyBytes: (await _keys()).metadataKeyBytes,
        ),
      );

  String _shortId(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);
}
