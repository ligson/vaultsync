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

class UploadApiService implements UploadGateway {
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
      },
    );
    return UploadSession.fromJson(data);
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

  const UploadSession({
    required this.id,
    required this.status,
    this.totalSize = 0,
    this.chunkSize = 0,
    this.receivedSize = 0,
  });

  factory UploadSession.fromJson(Map<String, Object?> json) {
    return UploadSession(
      id: json['id'] as String,
      status: json['status'] as String,
      totalSize: json['total_size'] as int? ?? 0,
      chunkSize: json['chunk_size'] as int? ?? 0,
      receivedSize: json['received_size'] as int? ?? 0,
    );
  }
}

class UploadedFileVersion {
  final String id;

  const UploadedFileVersion({required this.id});

  factory UploadedFileVersion.fromJson(Map<String, Object?> json) {
    return UploadedFileVersion(id: json['id'] as String);
  }
}
