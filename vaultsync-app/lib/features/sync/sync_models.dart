class SyncRoot {
  final String id;
  final String userId;
  final String deviceId;
  final String deviceName;
  final String encryptedPath;
  final bool encryptionEnabled;
  final String cleanupPolicy;
  final String archivePath;
  final String createdAt;

  const SyncRoot({
    required this.id,
    required this.userId,
    required this.deviceId,
    this.deviceName = '',
    required this.encryptedPath,
    this.encryptionEnabled = true,
    required this.cleanupPolicy,
    required this.archivePath,
    required this.createdAt,
  });

  factory SyncRoot.fromJson(Map<String, Object?> json) {
    return SyncRoot(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      deviceId: json['device_id'] as String,
      deviceName: json['device_name'] as String? ?? '',
      encryptedPath: json['encrypted_path'] as String,
      encryptionEnabled: json['encryption_enabled'] as bool? ?? true,
      cleanupPolicy: json['cleanup_policy'] as String,
      archivePath: json['archive_path'] as String? ?? '',
      createdAt: json['created_at'] as String,
    );
  }
}

class LocalSyncRootMapping {
  final String syncRootId;
  final String localPath;
  final String encryptedPath;
  final bool encryptionEnabled;
  final String cleanupPolicy;
  final String archivePath;

  const LocalSyncRootMapping({
    required this.syncRootId,
    required this.localPath,
    required this.encryptedPath,
    this.encryptionEnabled = true,
    required this.cleanupPolicy,
    required this.archivePath,
  });

  factory LocalSyncRootMapping.fromJson(Map<String, Object?> json) {
    return LocalSyncRootMapping(
      syncRootId: json['sync_root_id'] as String,
      localPath: json['local_path'] as String,
      encryptedPath: json['encrypted_path'] as String,
      encryptionEnabled: json['encryption_enabled'] as bool? ?? true,
      cleanupPolicy: json['cleanup_policy'] as String,
      archivePath: json['archive_path'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'sync_root_id': syncRootId,
      'local_path': localPath,
      'encrypted_path': encryptedPath,
      'encryption_enabled': encryptionEnabled,
      'cleanup_policy': cleanupPolicy,
      'archive_path': archivePath,
    };
  }
}

class LocalSyncFile {
  final String syncRootId;
  final String localPath;
  final String relativePath;
  final int sizeBytes;
  final DateTime modifiedAt;
  final bool encryptionEnabled;

  const LocalSyncFile({
    required this.syncRootId,
    required this.localPath,
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedAt,
    this.encryptionEnabled = true,
  });
}

class LocalUploadTask {
  final String id;
  final String syncRootId;
  final String localPath;
  final String relativePath;
  final int sizeBytes;
  final DateTime modifiedAt;
  final String status;
  final int attempts;
  final DateTime createdAt;
  final DateTime? stabilityObservedAt;
  final String sourceContentHash;
  final String lastError;
  final String uploadSessionId;
  final String uploadPayloadHash;
  final int uploadTotalSize;
  final int uploadChunkSize;
  final int uploadedBytes;
  final String sourceType;
  final String assetId;
  final String assetMediaType;
  final bool encryptionEnabled;

  const LocalUploadTask({
    required this.id,
    required this.syncRootId,
    required this.localPath,
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.status,
    required this.attempts,
    required this.createdAt,
    this.stabilityObservedAt,
    this.sourceContentHash = '',
    this.lastError = '',
    this.uploadSessionId = '',
    this.uploadPayloadHash = '',
    this.uploadTotalSize = 0,
    this.uploadChunkSize = 0,
    this.uploadedBytes = 0,
    this.sourceType = 'file',
    this.assetId = '',
    this.assetMediaType = '',
    this.encryptionEnabled = true,
  });

  factory LocalUploadTask.fromJson(Map<String, Object?> json) {
    return LocalUploadTask(
      id: json['id'] as String,
      syncRootId: json['sync_root_id'] as String,
      localPath: json['local_path'] as String,
      relativePath: json['relative_path'] as String,
      sizeBytes: json['size_bytes'] as int,
      modifiedAt: DateTime.parse(json['modified_at'] as String),
      status: json['status'] as String,
      attempts: json['attempts'] as int,
      createdAt: DateTime.parse(json['created_at'] as String),
      stabilityObservedAt: _optionalDateTime(json['stability_observed_at']),
      sourceContentHash: json['source_content_hash'] as String? ?? '',
      lastError: json['last_error'] as String? ?? '',
      uploadSessionId: json['upload_session_id'] as String? ?? '',
      uploadPayloadHash: json['upload_payload_hash'] as String? ?? '',
      uploadTotalSize: json['upload_total_size'] as int? ?? 0,
      uploadChunkSize: json['upload_chunk_size'] as int? ?? 0,
      uploadedBytes: json['uploaded_bytes'] as int? ?? 0,
      sourceType: json['source_type'] as String? ?? 'file',
      assetId: json['asset_id'] as String? ?? '',
      assetMediaType: json['asset_media_type'] as String? ?? '',
      encryptionEnabled: json['encryption_enabled'] as bool? ?? true,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'sync_root_id': syncRootId,
      'local_path': localPath,
      'relative_path': relativePath,
      'size_bytes': sizeBytes,
      'modified_at': modifiedAt.toIso8601String(),
      'status': status,
      'attempts': attempts,
      'created_at': createdAt.toIso8601String(),
      'stability_observed_at': stabilityObservedAt?.toIso8601String(),
      'source_content_hash': sourceContentHash,
      'last_error': lastError,
      'upload_session_id': uploadSessionId,
      'upload_payload_hash': uploadPayloadHash,
      'upload_total_size': uploadTotalSize,
      'upload_chunk_size': uploadChunkSize,
      'uploaded_bytes': uploadedBytes,
      'source_type': sourceType,
      'asset_id': assetId,
      'asset_media_type': assetMediaType,
      'encryption_enabled': encryptionEnabled,
    };
  }
}

class AutoSyncStatus {
  final DateTime? lastStartedAt;
  final DateTime? lastFinishedAt;
  final DateTime? lastSuccessAt;
  final String status;
  final String message;
  final int scannedCount;
  final int uploadedCount;
  final int failedCount;
  final int downloadedCount;
  final int remoteDeleteCount;
  final int blockedDeleteCount;

  const AutoSyncStatus({
    this.lastStartedAt,
    this.lastFinishedAt,
    this.lastSuccessAt,
    this.status = 'idle',
    this.message = '',
    this.scannedCount = 0,
    this.uploadedCount = 0,
    this.failedCount = 0,
    this.downloadedCount = 0,
    this.remoteDeleteCount = 0,
    this.blockedDeleteCount = 0,
  });

  factory AutoSyncStatus.fromJson(Map<String, Object?> json) {
    return AutoSyncStatus(
      lastStartedAt: _optionalDateTime(json['last_started_at']),
      lastFinishedAt: _optionalDateTime(json['last_finished_at']),
      lastSuccessAt: _optionalDateTime(json['last_success_at']),
      status: json['status'] as String? ?? 'idle',
      message: json['message'] as String? ?? '',
      scannedCount: json['scanned_count'] as int? ?? 0,
      uploadedCount: json['uploaded_count'] as int? ?? 0,
      failedCount: json['failed_count'] as int? ?? 0,
      downloadedCount: json['downloaded_count'] as int? ?? 0,
      remoteDeleteCount: json['remote_delete_count'] as int? ?? 0,
      blockedDeleteCount: json['blocked_delete_count'] as int? ?? 0,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'last_started_at': lastStartedAt?.toIso8601String(),
      'last_finished_at': lastFinishedAt?.toIso8601String(),
      'last_success_at': lastSuccessAt?.toIso8601String(),
      'status': status,
      'message': message,
      'scanned_count': scannedCount,
      'uploaded_count': uploadedCount,
      'failed_count': failedCount,
      'downloaded_count': downloadedCount,
      'remote_delete_count': remoteDeleteCount,
      'blocked_delete_count': blockedDeleteCount,
    };
  }
}

class LocalSyncOperationStatus {
  final String syncRootId;
  final String operation;
  final String source;
  final String status;
  final String message;
  final int itemCount;
  final DateTime startedAt;
  final DateTime? finishedAt;

  const LocalSyncOperationStatus({
    required this.syncRootId,
    required this.operation,
    required this.source,
    required this.status,
    this.message = '',
    this.itemCount = 0,
    required this.startedAt,
    this.finishedAt,
  });

  String get id => '$syncRootId:$operation';

  bool get isRunning => status == 'running';

  factory LocalSyncOperationStatus.fromJson(Map<String, Object?> json) {
    return LocalSyncOperationStatus(
      syncRootId: json['sync_root_id'] as String,
      operation: json['operation'] as String,
      source: json['source'] as String? ?? 'manual',
      status: json['status'] as String? ?? 'idle',
      message: json['message'] as String? ?? '',
      itemCount: json['item_count'] as int? ?? 0,
      startedAt: DateTime.parse(json['started_at'] as String),
      finishedAt: _optionalDateTime(json['finished_at']),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'sync_root_id': syncRootId,
      'operation': operation,
      'source': source,
      'status': status,
      'message': message,
      'item_count': itemCount,
      'started_at': startedAt.toIso8601String(),
      'finished_at': finishedAt?.toIso8601String(),
    };
  }
}

class LocalSyncHistoryEntry {
  final String id;
  final String type;
  final String result;
  final String title;
  final String message;
  final String syncRootId;
  final String relativePath;
  final DateTime createdAt;

  const LocalSyncHistoryEntry({
    required this.id,
    required this.type,
    required this.result,
    required this.title,
    required this.message,
    this.syncRootId = '',
    this.relativePath = '',
    required this.createdAt,
  });

  factory LocalSyncHistoryEntry.fromJson(Map<String, Object?> json) {
    return LocalSyncHistoryEntry(
      id: json['id'] as String,
      type: json['type'] as String? ?? 'sync',
      result: json['result'] as String? ?? 'info',
      title: json['title'] as String? ?? '',
      message: json['message'] as String? ?? '',
      syncRootId: json['sync_root_id'] as String? ?? '',
      relativePath: json['relative_path'] as String? ?? '',
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'type': type,
      'result': result,
      'title': title,
      'message': message,
      'sync_root_id': syncRootId,
      'relative_path': relativePath,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

class LocalRemoteVersionIndex {
  final String syncRootId;
  final String objectId;
  final String versionId;
  final String relativePath;
  final String localPath;
  final String contentHash;

  const LocalRemoteVersionIndex({
    required this.syncRootId,
    required this.objectId,
    required this.versionId,
    required this.relativePath,
    required this.localPath,
    required this.contentHash,
  });

  factory LocalRemoteVersionIndex.fromJson(Map<String, Object?> json) {
    return LocalRemoteVersionIndex(
      syncRootId: json['sync_root_id'] as String,
      objectId: json['object_id'] as String,
      versionId: json['version_id'] as String,
      relativePath: json['relative_path'] as String,
      localPath: json['local_path'] as String,
      contentHash: json['content_hash'] as String,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'sync_root_id': syncRootId,
      'object_id': objectId,
      'version_id': versionId,
      'relative_path': relativePath,
      'local_path': localPath,
      'content_hash': contentHash,
    };
  }
}

DateTime? _optionalDateTime(Object? value) {
  final raw = value as String?;
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw);
}

class LocalSyncIssue {
  final String id;
  final String type;
  final String syncRootId;
  final String objectId;
  final String versionId;
  final String relativePath;
  final String localPath;
  final String message;
  final String status;
  final DateTime createdAt;

  const LocalSyncIssue({
    required this.id,
    required this.type,
    required this.syncRootId,
    required this.objectId,
    required this.versionId,
    required this.relativePath,
    required this.localPath,
    required this.message,
    required this.status,
    required this.createdAt,
  });

  factory LocalSyncIssue.fromJson(Map<String, Object?> json) {
    return LocalSyncIssue(
      id: json['id'] as String,
      type: json['type'] as String,
      syncRootId: json['sync_root_id'] as String,
      objectId: json['object_id'] as String,
      versionId: json['version_id'] as String? ?? '',
      relativePath: json['relative_path'] as String,
      localPath: json['local_path'] as String,
      message: json['message'] as String,
      status: json['status'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'type': type,
      'sync_root_id': syncRootId,
      'object_id': objectId,
      'version_id': versionId,
      'relative_path': relativePath,
      'local_path': localPath,
      'message': message,
      'status': status,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

class SyncChangeItem {
  final String id;
  final String changeType;
  final String versionId;
  final String objectId;
  final String syncRootId;
  final int cursorValue;
  final String encryptedName;
  final String contentHash;
  final int sizeBytes;
  final String metadataJson;
  final String createdAt;

  const SyncChangeItem({
    required this.id,
    required this.changeType,
    required this.versionId,
    required this.objectId,
    required this.syncRootId,
    required this.cursorValue,
    required this.encryptedName,
    required this.contentHash,
    required this.sizeBytes,
    required this.metadataJson,
    required this.createdAt,
  });

  factory SyncChangeItem.fromJson(Map<String, Object?> json) {
    final versionId = json['version_id'] as String? ?? '';
    final cursorValue = json['cursor_value'] as int;
    return SyncChangeItem(
      id:
          json['id'] as String? ??
          (versionId.isEmpty ? '$cursorValue' : versionId),
      changeType: json['change_type'] as String,
      versionId: versionId,
      objectId: json['object_id'] as String,
      syncRootId: json['sync_root_id'] as String,
      cursorValue: cursorValue,
      encryptedName: json['encrypted_name'] as String? ?? '',
      contentHash: json['content_hash'] as String? ?? '',
      sizeBytes: json['size_bytes'] as int? ?? 0,
      metadataJson: json['metadata_json'] as String? ?? '',
      createdAt: json['created_at'] as String,
    );
  }
}

class SyncChangePage {
  final List<SyncChangeItem> items;
  final int nextCursor;
  final bool hasMore;

  const SyncChangePage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  factory SyncChangePage.fromJson(Map<String, Object?> json) {
    final items = json['items'] as List? ?? const [];
    return SyncChangePage(
      items: items
          .map(
            (item) =>
                SyncChangeItem.fromJson(Map<String, Object?>.from(item as Map)),
          )
          .toList(),
      nextCursor: json['next_cursor'] as int,
      hasMore: json['has_more'] as bool,
    );
  }
}

class RemoteBackupObject {
  final int cursorValue;
  final String syncRootId;
  final String objectId;
  final String versionId;
  final String encryptedName;
  final String contentHash;
  final int sizeBytes;
  final String metadataJson;
  final String updatedAt;

  const RemoteBackupObject({
    required this.cursorValue,
    required this.syncRootId,
    required this.objectId,
    required this.versionId,
    required this.encryptedName,
    required this.contentHash,
    required this.sizeBytes,
    required this.metadataJson,
    required this.updatedAt,
  });

  factory RemoteBackupObject.fromJson(Map<String, Object?> json) {
    return RemoteBackupObject(
      cursorValue: json['cursor_value'] as int,
      syncRootId: json['sync_root_id'] as String,
      objectId: json['object_id'] as String,
      versionId: json['version_id'] as String,
      encryptedName: json['encrypted_name'] as String,
      contentHash: json['content_hash'] as String,
      sizeBytes: json['size_bytes'] as int,
      metadataJson: json['metadata_json'] as String,
      updatedAt: json['updated_at'] as String,
    );
  }
}

class RemoteBackupObjectPage {
  final List<RemoteBackupObject> items;
  final int nextCursor;
  final bool hasMore;

  const RemoteBackupObjectPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  factory RemoteBackupObjectPage.fromJson(Map<String, Object?> json) {
    final items = json['items'] as List? ?? const [];
    return RemoteBackupObjectPage(
      items: items
          .map(
            (item) => RemoteBackupObject.fromJson(
              Map<String, Object?>.from(item as Map),
            ),
          )
          .toList(),
      nextCursor: json['next_cursor'] as int,
      hasMore: json['has_more'] as bool,
    );
  }
}

class RemoteBackupEntry {
  final String syncRootId;
  final String objectId;
  final String versionId;
  final String name;
  final String relativePath;
  final int sizeBytes;
  final String updatedAt;
  final bool decryptable;
  final String encryptedName;
  final String metadataJson;
  final String contentHash;
  final String clientContentHash;

  const RemoteBackupEntry({
    required this.syncRootId,
    required this.objectId,
    required this.versionId,
    required this.name,
    required this.relativePath,
    required this.sizeBytes,
    required this.updatedAt,
    this.decryptable = true,
    this.encryptedName = '',
    this.metadataJson = '',
    this.contentHash = '',
    this.clientContentHash = '',
  });

  RemoteBackupEntry withPayloadMetadata({
    required String encryptedName,
    required String metadataJson,
  }) {
    return RemoteBackupEntry(
      syncRootId: syncRootId,
      objectId: objectId,
      versionId: versionId,
      name: name,
      relativePath: relativePath,
      sizeBytes: sizeBytes,
      updatedAt: updatedAt,
      decryptable: decryptable,
      encryptedName: encryptedName,
      metadataJson: metadataJson,
      contentHash: contentHash,
      clientContentHash: clientContentHash,
    );
  }
}
