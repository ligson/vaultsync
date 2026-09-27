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

  Future<List<DocumentBookshelfItem>> loadBookshelf();

  Future<DocumentBookshelfItem> updateBookshelf({
    required String documentId,
    required String sectionId,
    required int offset,
    required double progress,
  });

  Future<void> removeFromBookshelf(String documentId);
}

abstract interface class DocumentCenterBackfillGateway {
  Future<int> backfillHistory();
}

abstract interface class DocumentCenterPreviewGateway {
  Future<DocumentPreviewData> loadPreview(DocumentCenterEntry entry);

  Future<DocumentPreviewChunk> loadPreviewChunk(
    DocumentCenterEntry entry, {
    required String sectionId,
    required int offset,
    int limit = 16384,
  });
}

class DocumentCenterApiService
    implements
        DocumentCenterGateway,
        DocumentCenterBackfillGateway,
        DocumentCenterPreviewGateway {
  final ApiClient apiClient;
  final SessionStore sessionStore;
  final UploadKeyStore keyStore;
  Future<UploadKeyMaterial>? _keysFuture;
  Future<RemoteMetadataDecrypter>? _metadataDecrypterFuture;
  Future<int>? _backfillInFlight;
  final Map<String, Future<String?>> _rootNameCache = {};

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

  @override
  Future<List<DocumentBookshelfItem>> loadBookshelf() async {
    final data = await apiClient.get(
      '/api/v1/documents/bookshelf',
      token: await _token(),
    );
    return [
      for (final raw in data['items'] as List<Object?>? ?? const [])
        DocumentBookshelfItem.fromJson(Map<String, Object?>.from(raw! as Map)),
    ];
  }

  @override
  Future<DocumentBookshelfItem> updateBookshelf({
    required String documentId,
    required String sectionId,
    required int offset,
    required double progress,
  }) async {
    final data = await apiClient.put(
      '/api/v1/documents/bookshelf/${Uri.encodeComponent(documentId)}',
      token: await _token(),
      body: {'section_id': sectionId, 'offset': offset, 'progress': progress},
    );
    return DocumentBookshelfItem.fromJson(data);
  }

  @override
  Future<void> removeFromBookshelf(String documentId) async {
    await apiClient.delete(
      '/api/v1/documents/bookshelf/${Uri.encodeComponent(documentId)}',
      token: await _token(),
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
    final plainResult = await _backfillPlainPage(cursor: 0, limit: 5000);
    final plainIndexed = plainResult.$1;
    if (plainResult.$3) {
      unawaited(_continuePlainBackfill(cursor: plainResult.$2));
    }
    const pageSize = 40;
    if (plainIndexed > 0) {
      unawaited(_continueBackfill(cursor: 0, pageSize: pageSize));
      return plainIndexed;
    }
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
    return plainIndexed + indexed;
  }

  Future<(int, int, bool)> _backfillPlainPage({
    required int cursor,
    required int limit,
  }) async {
    final data = await apiClient.post(
      Uri(
        path: '/api/v1/documents/plain-indexes',
        queryParameters: {'cursor': '$cursor', 'limit': '$limit'},
      ).toString(),
      token: await _token(),
      body: const {},
    );
    return (
      (data['indexed_count'] as num?)?.toInt() ?? 0,
      (data['next_cursor'] as num?)?.toInt() ?? cursor,
      data['has_more'] as bool? ?? false,
    );
  }

  Future<void> _continuePlainBackfill({required int cursor}) async {
    try {
      var nextCursor = cursor;
      var hasMore = true;
      while (hasMore) {
        final result = await _backfillPlainPage(
          cursor: nextCursor,
          limit: 5000,
        );
        nextCursor = result.$2;
        hasMore = result.$3;
      }
    } catch (_) {
      // A later open resumes from the remaining unmarked plain documents.
    }
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
    final plainName = item['plain_name'] as String? ?? '';
    final plainRelativePath = item['plain_relative_path'] as String? ?? '';
    final encryptionEnabled = item['encryption_enabled'] as bool? ?? true;
    final decrypted = !encryptionEnabled && plainName.isNotEmpty
        ? RemoteBackupEntry(
            syncRootId: object.syncRootId,
            objectId: object.objectId,
            versionId: object.versionId,
            name: plainName,
            relativePath: plainRelativePath.isEmpty
                ? plainName
                : plainRelativePath,
            sizeBytes: object.sizeBytes,
            updatedAt: object.updatedAt,
            contentHash: object.contentHash,
          )
        : await (await _metadataDecrypter()).decrypt(object);
    final backup = decrypted.withPayloadMetadata(
      encryptedName: object.encryptedName,
      metadataJson: object.metadataJson,
    );
    final keys = await _keys();
    final encryptedRootPath = item['encrypted_root_path'] as String? ?? '';
    final rootName = await (_rootNameCache[encryptedRootPath] ??=
        _decryptRootName(
          encryptedDisplayName:
              item['encrypted_root_display_name'] as String? ?? '',
          encryptedPath: encryptedRootPath,
          keyBytes: keys.metadataKeyBytes,
        ));
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
      encryptionEnabled: encryptionEnabled,
      remoteBackup: backup,
    );
  }

  Future<String?> _decryptRootName({
    required String encryptedDisplayName,
    required String encryptedPath,
    required List<int> keyBytes,
  }) {
    return SyncRootDisplayNameProtector().decrypt(
      encryptedDisplayName: encryptedDisplayName,
      encryptedPath: encryptedPath,
      keyBytes: keyBytes,
    );
  }

  @override
  Future<DocumentPreviewData> loadPreview(DocumentCenterEntry entry) async {
    if (entry.encryptionEnabled) {
      throw Exception('为保护数据安全，加密文档不能在线预览，请下载后查看');
    }
    final data = await apiClient.get(
      '/api/v1/documents/${Uri.encodeComponent(entry.id)}/preview?mode=meta',
      token: await _token(),
    );
    final sections = [
      for (final raw in data['sections'] as List<Object?>? ?? const [])
        _previewSection(Map<String, Object?>.from(raw! as Map)),
    ];
    final token = await _token();
    final pdfPath =
        '/api/v1/documents/${Uri.encodeComponent(entry.id)}/content';
    return DocumentPreviewData(
      name: data['name'] as String? ?? entry.name,
      format: data['format'] as String? ?? entry.documentFormat,
      kind: data['kind'] as String? ?? 'text',
      sections: sections,
      pdfUri: data['kind'] == 'pdf' ? apiClient.resolveUri(pdfPath) : null,
      pdfHeaders: data['kind'] == 'pdf'
          ? {'authorization': 'Bearer $token'}
          : const {},
      truncated: data['truncated'] as bool? ?? false,
      paged: data['paged'] as bool? ?? false,
      totalBytes: (data['total_bytes'] as num?)?.toInt() ?? entry.sizeBytes,
    );
  }

  @override
  Future<DocumentPreviewChunk> loadPreviewChunk(
    DocumentCenterEntry entry, {
    required String sectionId,
    required int offset,
    int limit = 16384,
  }) async {
    if (entry.encryptionEnabled) {
      throw Exception('为保护数据安全，加密文档不能在线预览，请下载后查看');
    }
    final query = Uri(
      path: '/api/v1/documents/${Uri.encodeComponent(entry.id)}/preview',
      queryParameters: {
        'mode': 'page',
        'section_id': sectionId,
        'offset': '$offset',
        'limit': '$limit',
      },
    ).toString();
    final data = await apiClient.get(query, token: await _token());
    return DocumentPreviewChunk(
      sectionId: data['section_id'] as String? ?? sectionId,
      offset: (data['offset'] as num?)?.toInt() ?? offset,
      nextOffset: (data['next_offset'] as num?)?.toInt() ?? offset,
      hasMore: data['has_more'] as bool? ?? false,
      content:
          data['sections'] is List<Object?> &&
              (data['sections'] as List<Object?>).isNotEmpty
          ? _previewSection(
              Map<String, Object?>.from(
                ((data['sections'] as List<Object?>).first! as Map),
              ),
            ).content
          : '',
    );
  }

  DocumentPreviewSection _previewSection(Map<String, Object?> item) =>
      DocumentPreviewSection(
        id: item['id'] as String? ?? '',
        title: item['title'] as String? ?? '正文',
        content: item['content'] as String? ?? '',
      );

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
