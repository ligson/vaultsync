import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'sync_models.dart';
import 'upload_key_store.dart';

abstract interface class RemoteMetadataDecrypter {
  Future<RemoteBackupEntry> decrypt(RemoteBackupObject object);
}

class StoredRemoteMetadataDecrypter implements RemoteMetadataDecrypter {
  final UploadKeyStore keyStore;
  final Cipher cipher;

  StoredRemoteMetadataDecrypter({required this.keyStore, Cipher? cipher})
    : cipher = cipher ?? Xchacha20.poly1305Aead();

  @override
  Future<RemoteBackupEntry> decrypt(RemoteBackupObject object) async {
    final keys = await keyStore.loadUploadKeys();
    return XChaCha20RemoteMetadataDecrypter(
      metadataKeyBytes: keys.metadataKeyBytes,
      cipher: cipher,
    ).decrypt(object);
  }
}

class XChaCha20RemoteMetadataDecrypter implements RemoteMetadataDecrypter {
  static const _nonceLength = 24;
  static const _namePrefix = 'vaultsync-name:v1:';

  final SecretKey metadataKey;
  final Cipher cipher;

  XChaCha20RemoteMetadataDecrypter({
    required List<int> metadataKeyBytes,
    Cipher? cipher,
  }) : cipher = cipher ?? Xchacha20.poly1305Aead(),
       metadataKey = SecretKey(metadataKeyBytes);

  @override
  Future<RemoteBackupEntry> decrypt(RemoteBackupObject object) async {
    try {
      final metadata = await _decryptMetadata(object);
      final name = await _decryptName(object);
      return RemoteBackupEntry(
        syncRootId: object.syncRootId,
        objectId: object.objectId,
        versionId: object.versionId,
        name: name,
        relativePath: metadata['relative_path'] as String? ?? name,
        sizeBytes: object.sizeBytes,
        updatedAt: object.updatedAt,
      );
    } catch (_) {
      return RemoteBackupEntry(
        syncRootId: object.syncRootId,
        objectId: object.objectId,
        versionId: object.versionId,
        name: '无法解密的备份对象',
        relativePath: '无法解密的备份对象 ${_shortObjectId(object.objectId)}',
        sizeBytes: object.sizeBytes,
        updatedAt: object.updatedAt,
        decryptable: false,
      );
    }
  }

  Future<Map<String, Object?>> _decryptMetadata(
    RemoteBackupObject object,
  ) async {
    final metadataEnvelope =
        jsonDecode(object.metadataJson) as Map<String, Object?>;
    if (metadataEnvelope['format'] != 'vaultsync-metadata-v1') {
      throw Exception('元数据格式无效');
    }
    final clearText = await _decryptBox(
      nonce: _base64UrlDecode(metadataEnvelope['nonce'] as String),
      ciphertextAndMac: _base64UrlDecode(
        metadataEnvelope['ciphertext'] as String,
      ),
      aad: utf8.encode(
        'vaultsync/v1/metadata|${object.syncRootId}|${object.objectId}|${object.versionId}',
      ),
    );
    return jsonDecode(utf8.decode(clearText)) as Map<String, Object?>;
  }

  Future<String> _decryptName(RemoteBackupObject object) async {
    final encryptedName = object.encryptedName;
    if (!encryptedName.startsWith(_namePrefix)) {
      throw Exception('加密文件名格式无效');
    }
    final bytes = _base64UrlDecode(encryptedName.substring(_namePrefix.length));
    if (bytes.length <= _nonceLength) {
      throw Exception('加密文件名格式无效');
    }
    final clearText = await _decryptBox(
      nonce: bytes.sublist(0, _nonceLength),
      ciphertextAndMac: bytes.sublist(_nonceLength),
      aad: utf8.encode(
        'vaultsync/v1/name|${object.syncRootId}|${object.objectId}|${object.versionId}',
      ),
    );
    return utf8.decode(clearText);
  }

  Future<List<int>> _decryptBox({
    required List<int> nonce,
    required List<int> ciphertextAndMac,
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
      secretKey: metadataKey,
      aad: aad,
    );
  }

  List<int> _base64UrlDecode(String value) {
    return base64Url.decode(base64Url.normalize(value));
  }

  String _shortObjectId(String objectId) {
    return objectId.length <= 8 ? objectId : objectId.substring(0, 8);
  }
}
