import '../../core/network/api_client.dart';
import 'download_models.dart';

abstract interface class DownloadGateway {
  Future<DownloadedObject> downloadCiphertext({
    required String token,
    required String versionId,
    required String objectId,
    required String syncRootId,
    required String encryptedName,
  });
}

class DownloadService implements DownloadGateway {
  final ApiClient apiClient;

  const DownloadService(this.apiClient);

  @override
  Future<DownloadedObject> downloadCiphertext({
    required String token,
    required String versionId,
    required String objectId,
    required String syncRootId,
    required String encryptedName,
  }) async {
    final bytes = await apiClient.getBytes(
      '/api/v1/objects/$versionId',
      token: token,
    );
    return DownloadedObject(
      versionId: versionId,
      objectId: objectId,
      syncRootId: syncRootId,
      encryptedName: encryptedName,
      bytes: bytes,
    );
  }
}
