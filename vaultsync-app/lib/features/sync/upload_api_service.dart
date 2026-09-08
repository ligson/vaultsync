import '../../core/network/api_client.dart';

abstract interface class UploadGateway {
  Future<UploadSession> createUploadSession({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
    required String versionId,
    required int totalSize,
    required int chunkSize,
    required String encryptedName,
    required String metadataJson,
  });

  Future<UploadSession> getUploadSession({
    required String token,
    required String sessionId,
  });

  Future<void> uploadPart({
    required String token,
    required String sessionId,
    required int partIndex,
    required List<int> bytes,
  });

  Future<UploadedFileVersion> completeUploadSession({
    required String token,
    required String sessionId,
  });
}

class MediaUploadIndex {
  final String mediaType;
  final DateTime capturedAt;
  final int capturedYear;
  final int capturedMonth;
  final int width;
  final int height;
  final int durationMs;

  const MediaUploadIndex({
    required this.mediaType,
    required this.capturedAt,
    this.capturedYear = 0,
    this.capturedMonth = 0,
    this.width = 0,
    this.height = 0,
    this.durationMs = 0,
  });

  Map<String, Object?> toJson() => {
    'media_type': mediaType,
    'captured_at': capturedAt.toUtc().toIso8601String(),
    if (capturedYear > 0) 'captured_year': capturedYear,
    if (capturedMonth > 0) 'captured_month': capturedMonth,
    'width': width,
    'height': height,
    'duration_ms': durationMs,
  };
}

abstract interface class MediaIndexedUploadGateway {
  Future<UploadSession> createMediaUploadSession({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
    required String versionId,
    required int totalSize,
    required int chunkSize,
    required String encryptedName,
    required String metadataJson,
    required MediaUploadIndex mediaIndex,
  });
}

abstract interface class MediaThumbnailUploadGateway {
  Future<void> uploadMediaThumbnail({
    required String token,
    required String mediaId,
    required List<int> bytes,
  });
}

class UploadApiService
    implements
        UploadGateway,
        MediaIndexedUploadGateway,
        MediaThumbnailUploadGateway {
  final ApiClient apiClient;

  const UploadApiService(this.apiClient);

  @override
  Future<UploadSession> createUploadSession({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
    required String versionId,
    required int totalSize,
    required int chunkSize,
    required String encryptedName,
    required String metadataJson,
  }) async {
    return _createUploadSession(
      token: token,
      deviceId: deviceId,
      syncRootId: syncRootId,
      objectId: objectId,
      versionId: versionId,
      totalSize: totalSize,
      chunkSize: chunkSize,
      encryptedName: encryptedName,
      metadataJson: metadataJson,
    );
  }

  @override
  Future<UploadSession> createMediaUploadSession({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
    required String versionId,
    required int totalSize,
    required int chunkSize,
    required String encryptedName,
    required String metadataJson,
    required MediaUploadIndex mediaIndex,
  }) {
    return _createUploadSession(
      token: token,
      deviceId: deviceId,
      syncRootId: syncRootId,
      objectId: objectId,
      versionId: versionId,
      totalSize: totalSize,
      chunkSize: chunkSize,
      encryptedName: encryptedName,
      metadataJson: metadataJson,
      mediaIndex: mediaIndex,
    );
  }

  Future<UploadSession> _createUploadSession({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
    required String versionId,
    required int totalSize,
    required int chunkSize,
    required String encryptedName,
    required String metadataJson,
    MediaUploadIndex? mediaIndex,
  }) async {
    final data = await apiClient.post(
      '/api/v1/upload-sessions',
      token: token,
      body: {
        'device_id': deviceId,
        'sync_root_id': syncRootId,
        'object_id': objectId,
        'version_id': versionId,
        'total_size': totalSize,
        'chunk_size': chunkSize,
        'encrypted_name': encryptedName,
        'metadata_json': metadataJson,
        if (mediaIndex != null) 'media_index': mediaIndex.toJson(),
      },
    );
    return UploadSession.fromJson(data);
  }

  @override
  Future<void> uploadMediaThumbnail({
    required String token,
    required String mediaId,
    required List<int> bytes,
  }) {
    return apiClient.putBytes(
      '/api/v1/media/$mediaId/thumbnail',
      token: token,
      bytes: bytes,
    );
  }

  @override
  Future<UploadSession> getUploadSession({
    required String token,
    required String sessionId,
  }) async {
    final data = await apiClient.get(
      '/api/v1/upload-sessions/$sessionId',
      token: token,
    );
    return UploadSession.fromJson(data);
  }

  @override
  Future<void> uploadPart({
    required String token,
    required String sessionId,
    required int partIndex,
    required List<int> bytes,
  }) {
    return apiClient.putBytes(
      '/api/v1/upload-sessions/$sessionId/parts/$partIndex',
      token: token,
      bytes: bytes,
    );
  }

  @override
  Future<UploadedFileVersion> completeUploadSession({
    required String token,
    required String sessionId,
  }) async {
    final data = await apiClient.post(
      '/api/v1/upload-sessions/$sessionId/complete',
      token: token,
      body: const {},
    );
    return UploadedFileVersion.fromJson(data);
  }
}

class UploadSession {
  final String id;
  final String status;
  final int totalSize;
  final int chunkSize;
  final int receivedSize;
  final String mediaId;

  const UploadSession({
    required this.id,
    required this.status,
    this.totalSize = 0,
    this.chunkSize = 0,
    this.receivedSize = 0,
    this.mediaId = '',
  });

  factory UploadSession.fromJson(Map<String, Object?> json) {
    return UploadSession(
      id: json['id'] as String,
      status: json['status'] as String,
      totalSize: json['total_size'] as int? ?? 0,
      chunkSize: json['chunk_size'] as int? ?? 0,
      receivedSize: json['received_size'] as int? ?? 0,
      mediaId: json['media_id'] as String? ?? '',
    );
  }
}

class UploadedFileVersion {
  final String id;
  final String mediaId;

  const UploadedFileVersion({required this.id, this.mediaId = ''});

  factory UploadedFileVersion.fromJson(Map<String, Object?> json) {
    return UploadedFileVersion(
      id: json['id'] as String,
      mediaId: json['media_id'] as String? ?? '',
    );
  }
}
