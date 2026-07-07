import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'upload_key_store.dart';

class DecryptedRemoteObject {
  final String name;
  final String relativePath;
  final Map<String, Object?> metadata;
  final List<int> bytes;

  const DecryptedRemoteObject({
    required this.name,
    required this.relativePath,
    required this.metadata,
    required this.bytes,
  });
}

abstract interface class DownloadPayloadDecrypter {
  Future<DecryptedRemoteObject> decrypt({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required String encryptedName,
    required String metadataJson,
    required List<int> payloadBytes,
  });
}

class StoredEncryptedDownloadPayloadDecrypter
    implements DownloadPayloadDecrypter {
  final UploadKeyStore keyStore;
  final Cipher cipher;

  StoredEncryptedDownloadPayloadDecrypter({
    required this.keyStore,
    Cipher? cipher,
  }) : cipher = cipher ?? Xchacha20.poly1305Aead();

  @override
  Future<DecryptedRemoteObject> decrypt({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required String encryptedName,
    required String metadataJson,
    required List<int> payloadBytes,
  }) async {
    final keys = await keyStore.loadUploadKeys();
    return EncryptedDownloadPayloadDecrypter(
      contentKeyBytes: keys.contentKeyBytes,
      metadataKeyBytes: keys.metadataKeyBytes,
      cipher: cipher,
    ).decrypt(
      syncRootId: syncRootId,
      objectId: objectId,
      versionId: versionId,
      encryptedName: encryptedName,
      metadataJson: metadataJson,
      payloadBytes: payloadBytes,
    );
  }
}

class EncryptedDownloadPayloadDecrypter implements DownloadPayloadDecrypter {
  static const _magic = 'VSENC001';
  static const _algId = 0x01;
  static const _nonceLength = 24;

  final SecretKey contentKey;
  final SecretKey metadataKey;
  final Cipher cipher;

  EncryptedDownloadPayloadDecrypter({
    required List<int> contentKeyBytes,
    required List<int> metadataKeyBytes,
    Cipher? cipher,
  }) : cipher = cipher ?? Xchacha20.poly1305Aead(),
       contentKey = SecretKey(contentKeyBytes),
       metadataKey = SecretKey(metadataKeyBytes);

  @override
  Future<DecryptedRemoteObject> decrypt({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required String encryptedName,
    required String metadataJson,
    required List<int> payloadBytes,
  }) async {
    final bytes = await _decryptContent(
      payloadBytes,
      syncRootId,
      objectId,
      versionId,
    );
    final metadata = await _decryptMetadata(
      metadataJson,
      syncRootId,
      objectId,
      versionId,
    );
    final name = await _decryptName(
      encryptedName,
      syncRootId,
      objectId,
      versionId,
    );
    return DecryptedRemoteObject(
      name: name,
      relativePath: metadata['relative_path'] as String? ?? name,
      metadata: metadata,
      bytes: bytes,
    );
  }

  Future<List<int>> _decryptContent(
    List<int> payload,
    String syncRootId,
    String objectId,
    String versionId,
  ) {
    if (payload.length < _magic.length + 2 + _nonceLength) {
      throw Exception('密文格式无效');
    }
    final magic = String.fromCharCodes(payload.take(_magic.length));
    final algId = payload[_magic.length];
    final nonceLength = payload[_magic.length + 1];
    if (magic != _magic || algId != _algId || nonceLength != _nonceLength) {
      throw Exception('密文格式无效');
    }
    final nonceStart = _magic.length + 2;
    final cipherStart = nonceStart + nonceLength;
    final nonce = payload.sublist(nonceStart, cipherStart);
    final ciphertextAndMac = payload.sublist(cipherStart);
    return _decryptBox(
      nonce: nonce,
      ciphertextAndMac: ciphertextAndMac,
      secretKey: contentKey,
      aad: utf8.encode('vaultsync/v1/content|$syncRootId|$objectId|$versionId'),
    );
  }

  Future<Map<String, Object?>> _decryptMetadata(
    String metadataJson,
    String syncRootId,
    String objectId,
    String versionId,
  ) async {
    final metadataEnvelope = jsonDecode(metadataJson) as Map<String, Object?>;
    if (metadataEnvelope['format'] != 'vaultsync-metadata-v1') {
      throw Exception('元数据格式无效');
    }
    final nonce = _base64UrlDecode(metadataEnvelope['nonce'] as String);
    final ciphertextAndMac = _base64UrlDecode(
      metadataEnvelope['ciphertext'] as String,
    );
    final clearText = await _decryptBox(
      nonce: nonce,
      ciphertextAndMac: ciphertextAndMac,
      secretKey: metadataKey,
      aad: utf8.encode(
        'vaultsync/v1/metadata|$syncRootId|$objectId|$versionId',
      ),
    );
    return jsonDecode(utf8.decode(clearText)) as Map<String, Object?>;
  }

  Future<String> _decryptName(
    String encryptedName,
    String syncRootId,
    String objectId,
    String versionId,
  ) async {
    const prefix = 'vaultsync-name:v1:';
    if (!encryptedName.startsWith(prefix)) {
      throw Exception('加密文件名格式无效');
    }
    final bytes = _base64UrlDecode(encryptedName.substring(prefix.length));
    if (bytes.length <= _nonceLength) {
      throw Exception('加密文件名格式无效');
    }
    final clearText = await _decryptBox(
      nonce: bytes.sublist(0, _nonceLength),
      ciphertextAndMac: bytes.sublist(_nonceLength),
      secretKey: metadataKey,
      aad: utf8.encode('vaultsync/v1/name|$syncRootId|$objectId|$versionId'),
    );
    return utf8.decode(clearText);
  }

  Future<List<int>> _decryptBox({
    required List<int> nonce,
    required List<int> ciphertextAndMac,
    required SecretKey secretKey,
    required List<int> aad,
  }) {
    final macLength = cipher.macAlgorithm.macLength;
    if (ciphertextAndMac.length <= macLength) {
      throw Exception('密文格式无效');
    }
    final ciphertext = ciphertextAndMac.sublist(
      0,
      ciphertextAndMac.length - macLength,
    );
    final mac = ciphertextAndMac.sublist(ciphertextAndMac.length - macLength);
    return cipher.decrypt(
      SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
      secretKey: secretKey,
      aad: aad,
    );
  }

  List<int> _base64UrlDecode(String value) {
    return base64Url.decode(base64Url.normalize(value));
  }
}
