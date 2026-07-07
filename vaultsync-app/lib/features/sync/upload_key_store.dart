const uploadKeyLength = 32;

abstract interface class UploadKeyStore {
  Future<UploadKeyMaterial> loadUploadKeys();

  Future<UploadKeyMaterial> deriveAndSaveUploadKeys({
    required String email,
    required String password,
  });
}

class MissingUploadKeyException implements Exception {
  final String message;

  const MissingUploadKeyException([this.message = '本地加密密钥不存在，请重新登录']);

  @override
  String toString() => message;
}

class UploadKeyMaterial {
  final List<int> contentKeyBytes;
  final List<int> metadataKeyBytes;

  const UploadKeyMaterial({
    required this.contentKeyBytes,
    required this.metadataKeyBytes,
  });
}
