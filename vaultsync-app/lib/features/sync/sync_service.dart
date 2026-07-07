import '../../core/network/api_client.dart';
import 'sync_models.dart';

abstract interface class SyncRootGateway {
  Future<List<SyncRoot>> listSyncRoots({required String token});

  Future<SyncRoot> createSyncRoot({
    required String token,
    required String deviceId,
    required String encryptedPath,
    required String cleanupPolicy,
    required String archivePath,
  });

  Future<SyncRoot> updateSyncRootCleanupPolicy({
    required String token,
    required String syncRootId,
    required String cleanupPolicy,
  });

  Future<void> deleteSyncRoot({
    required String token,
    required String syncRootId,
    required bool deleteRemote,
  });
}

abstract interface class SyncChangeGateway {
  Future<SyncChangePage> listChanges({
    required String token,
    required String deviceId,
    required int cursor,
    int limit,
  });
}

abstract interface class RemoteBackupGateway {
  Future<RemoteBackupObjectPage> listRemoteBackupObjects({
    required String token,
    required String syncRootId,
    int cursor,
    int limit,
  });
}

abstract interface class RemoteObjectDeleteGateway {
  Future<void> deleteRemoteObject({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
  });
}

class SyncService
    implements
        SyncRootGateway,
        SyncChangeGateway,
        RemoteBackupGateway,
        RemoteObjectDeleteGateway {
  final ApiClient apiClient;

  const SyncService(this.apiClient);

  @override
  Future<List<SyncRoot>> listSyncRoots({required String token}) async {
    final data = await apiClient.get('/api/v1/sync-roots', token: token);
    final items = data['items'] as List? ?? const [];
    return items
        .map(
          (item) => SyncRoot.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList();
  }

  @override
  Future<SyncRoot> createSyncRoot({
    required String token,
    required String deviceId,
    required String encryptedPath,
    required String cleanupPolicy,
    required String archivePath,
  }) async {
    final data = await apiClient.post(
      '/api/v1/sync-roots',
      token: token,
      body: {
        'device_id': deviceId,
        'encrypted_path': encryptedPath,
        'cleanup_policy': cleanupPolicy,
        'archive_path': archivePath,
      },
    );
    return SyncRoot.fromJson(data);
  }

  @override
  Future<SyncRoot> updateSyncRootCleanupPolicy({
    required String token,
    required String syncRootId,
    required String cleanupPolicy,
  }) async {
    final data = await apiClient.patch(
      '/api/v1/sync-roots/$syncRootId',
      token: token,
      body: {'cleanup_policy': cleanupPolicy},
    );
    return SyncRoot.fromJson(data);
  }

  @override
  Future<void> deleteSyncRoot({
    required String token,
    required String syncRootId,
    required bool deleteRemote,
  }) async {
    await apiClient.delete(
      '/api/v1/sync-roots/$syncRootId?delete_remote=$deleteRemote',
      token: token,
    );
  }

  @override
  Future<SyncChangePage> listChanges({
    required String token,
    required String deviceId,
    required int cursor,
    int limit = 100,
  }) async {
    final query = Uri(
      path: '/api/v1/changes',
      queryParameters: {
        'cursor': '$cursor',
        'device_id': deviceId,
        'limit': '$limit',
      },
    ).toString();
    final data = await apiClient.get(query, token: token);
    return SyncChangePage.fromJson(data);
  }

  @override
  Future<RemoteBackupObjectPage> listRemoteBackupObjects({
    required String token,
    required String syncRootId,
    int cursor = 0,
    int limit = 100,
  }) async {
    final query = Uri(
      path: '/api/v1/sync-roots/$syncRootId/remote-objects',
      queryParameters: {'cursor': '$cursor', 'limit': '$limit'},
    ).toString();
    final data = await apiClient.get(query, token: token);
    return RemoteBackupObjectPage.fromJson(data);
  }

  @override
  Future<void> deleteRemoteObject({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
  }) async {
    final query = Uri(
      path: '/api/v1/objects/$objectId',
      queryParameters: {'sync_root_id': syncRootId, 'device_id': deviceId},
    ).toString();
    await apiClient.delete(query, token: token);
  }
}
