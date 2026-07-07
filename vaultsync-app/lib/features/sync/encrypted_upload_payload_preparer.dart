import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'local_upload_executor.dart';
import 'sync_models.dart';
import 'upload_key_store.dart';

abstract interface class UploadNonceFactory {
  List<int> nextNonce();
}

class RandomUploadNonceFactory implements UploadNonceFactory {
  final Cipher cipher;

  const RandomUploadNonceFactory(this.cipher);

  @override
  List<int> nextNonce() => cipher.newNonce();
}

abstract interface class UploadContentReader {
  Future<List<int>> read(LocalUploadTask task);
}

class FileUploadContentReader implements UploadContentReader {
  const FileUploadContentReader();

  @override
  Future<List<int>> read(LocalUploadTask task) {
    return File(task.localPath).readAsBytes();
  }
}

class StoredEncryptedUploadPayloadPreparer implements UploadPayloadPreparer {
  final UploadKeyStore keyStore;
  final Cipher cipher;
  final UploadContentReader contentReader;

  StoredEncryptedUploadPayloadPreparer({
    required this.keyStore,
    Cipher? cipher,
    UploadContentReader? contentReader,
  }) : cipher = cipher ?? Xchacha20.poly1305Aead(),
       contentReader = contentReader ?? const FileUploadContentReader();

  @override
  Future<PreparedUploadPayload> prepare(
    LocalUploadTask task, {
    required String objectId,
    required String versionId,
  }) async {
    final keys = await keyStore.loadUploadKeys();
    return EncryptedUploadPayloadPreparer(
      contentKeyBytes: keys.contentKeyBytes,
      metadataKeyBytes: keys.metadataKeyBytes,
      cipher: cipher,
      contentReader: contentReader,
    ).prepare(task, objectId: objectId, versionId: versionId);
  }
}

class EncryptedUploadPayloadPreparer implements UploadPayloadPreparer {
  static const _magic = 'VSENC001';
  static const _algId = 0x01;

  final SecretKey contentKey;
  final SecretKey metadataKey;
  final List<int> contentKeyBytes;
  final List<int> metadataKeyBytes;
  final Cipher cipher;
  final UploadNonceFactory? nonceFactory;
  final UploadContentReader contentReader;

  // 这里保留原始 key bytes 用于按版本稳定派生上传 nonce，支持断点续传重试。
  // ignore: prefer_initializing_formals
  EncryptedUploadPayloadPreparer({
    required List<int> contentKeyBytes,
    required List<int> metadataKeyBytes,
    Cipher? cipher,
    this.nonceFactory,
    UploadContentReader? contentReader,
  }) : cipher = cipher ?? Xchacha20.poly1305Aead(),
       contentReader = contentReader ?? const FileUploadContentReader(),
       contentKeyBytes = List<int>.unmodifiable(contentKeyBytes),
       metadataKeyBytes = List<int>.unmodifiable(metadataKeyBytes),
       contentKey = SecretKey(contentKeyBytes),
       metadataKey = SecretKey(metadataKeyBytes);

  @override
  Future<PreparedUploadPayload> prepare(
    LocalUploadTask task, {
    required String objectId,
    required String versionId,
  }) async {
    final plainBytes = await contentReader.read(task);
    final contentAad = _contentAad(task, objectId, versionId);
    final contentBox = await _encrypt(
      plainBytes,
      secretKey: contentKey,
      nonce: _nonceFor(
        purpose: 'content',
        keyBytes: contentKeyBytes,
        aad: contentAad,
      ),
      aad: contentAad,
    );
    final metadata = await _metadataJson(task, objectId, versionId);
    final encryptedName = await _encryptedName(task, objectId, versionId);
    return PreparedUploadPayload(
      bytes: _contentPayload(contentBox),
      encryptedName: encryptedName,
      metadataJson: metadata,
    );
  }

  Future<String> _metadataJson(
    LocalUploadTask task,
    String objectId,
    String versionId,
  ) async {
    final metadataAad = _metadataAad(task, objectId, versionId);
    final plainMetadata = jsonEncode({
      'name': _fileName(task.relativePath),
      'relative_path': task.relativePath,
      'kind': 'file',
      'mtime_unix_ms': task.modifiedAt.millisecondsSinceEpoch,
      'client_size': task.sizeBytes,
    });
    final box = await _encrypt(
      utf8.encode(plainMetadata),
      secretKey: metadataKey,
      nonce: _nonceFor(
        purpose: 'metadata',
        keyBytes: metadataKeyBytes,
        aad: metadataAad,
      ),
      aad: metadataAad,
    );
    return jsonEncode({
      'format': 'vaultsync-metadata-v1',
      'alg': 'XChaCha20-Poly1305',
      'nonce': _base64(box.nonce),
      'ciphertext': _base64([...box.cipherText, ...box.mac.bytes]),
      'aad': {
        'sync_root_id': task.syncRootId,
        'object_id': objectId,
        'version_id': versionId,
      },
    });
  }

  Future<String> _encryptedName(
    LocalUploadTask task,
    String objectId,
    String versionId,
  ) async {
    final box = await _encrypt(
      utf8.encode(_fileName(task.relativePath)),
      secretKey: metadataKey,
      nonce: _nonceFor(
        purpose: 'name',
        keyBytes: metadataKeyBytes,
        aad: _nameAad(task, objectId, versionId),
      ),
      aad: _nameAad(task, objectId, versionId),
    );
    return 'vaultsync-name:v1:${_base64([...box.nonce, ...box.cipherText, ...box.mac.bytes])}';
  }

  Future<SecretBox> _encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    required List<int> nonce,
    required List<int> aad,
  }) {
    return cipher.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonceFactory?.nextNonce() ?? nonce,
      aad: aad,
    );
  }

  List<int> _nonceFor({
    required String purpose,
    required List<int> keyBytes,
    required List<int> aad,
  }) {
    final seed = utf8.encode('vaultsync/v1/upload-nonce|$purpose|');
    final digest = crypto.Hmac(
      crypto.sha256,
      keyBytes,
    ).convert([...seed, ...aad]);
    return digest.bytes.take(cipher.nonceLength).toList(growable: false);
  }

  List<int> _contentPayload(SecretBox box) {
    return [
      ..._magic.codeUnits,
      _algId,
      box.nonce.length,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
  }

  List<int> _contentAad(
    LocalUploadTask task,
    String objectId,
    String versionId,
  ) {
    return utf8.encode(
      'vaultsync/v1/content|${task.syncRootId}|$objectId|$versionId',
    );
  }

  List<int> _metadataAad(
    LocalUploadTask task,
    String objectId,
    String versionId,
  ) {
    return utf8.encode(
      'vaultsync/v1/metadata|${task.syncRootId}|$objectId|$versionId',
    );
  }

  List<int> _nameAad(LocalUploadTask task, String objectId, String versionId) {
    return utf8.encode(
      'vaultsync/v1/name|${task.syncRootId}|$objectId|$versionId',
    );
  }

  String _fileName(String relativePath) {
    return relativePath.replaceAll('\\', '/').split('/').last;
  }

  String _base64(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
