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

abstract interface class StreamingUploadContentReader
    implements UploadContentReader {
  Future<File?> resolveFile(LocalUploadTask task);
}

class FileUploadContentReader implements StreamingUploadContentReader {
  const FileUploadContentReader();

  @override
  Future<List<int>> read(LocalUploadTask task) {
    return File(task.localPath).readAsBytes();
  }

  @override
  Future<File?> resolveFile(LocalUploadTask task) async {
    final file = File(task.localPath);
    return await file.exists() ? file : null;
  }
}

typedef UploadCacheDirectoryProvider = Future<Directory> Function();

class StoredEncryptedUploadPayloadPreparer implements UploadPayloadPreparer {
  final UploadKeyStore keyStore;
  final Cipher cipher;
  final UploadContentReader contentReader;
  final UploadCacheDirectoryProvider? cacheDirectoryProvider;

  StoredEncryptedUploadPayloadPreparer({
    required this.keyStore,
    Cipher? cipher,
    UploadContentReader? contentReader,
    this.cacheDirectoryProvider,
  }) : cipher = cipher ?? Xchacha20.poly1305Aead(),
       contentReader = contentReader ?? const FileUploadContentReader();

  @override
  Future<PreparedUploadPayload> prepare(
    LocalUploadTask task, {
    required String objectId,
    required String versionId,
  }) async {
    if (!task.encryptionEnabled) {
      return PlainUploadPayloadPreparer(
        contentReader: contentReader,
      ).prepare(task, objectId: objectId, versionId: versionId);
    }
    final keys = await keyStore.loadUploadKeys();
    return EncryptedUploadPayloadPreparer(
      contentKeyBytes: keys.contentKeyBytes,
      metadataKeyBytes: keys.metadataKeyBytes,
      cipher: cipher,
      contentReader: contentReader,
      cacheDirectoryProvider: cacheDirectoryProvider,
    ).prepare(task, objectId: objectId, versionId: versionId);
  }
}

class PlainUploadPayloadPreparer implements UploadPayloadPreparer {
  final UploadContentReader contentReader;

  const PlainUploadPayloadPreparer({
    this.contentReader = const FileUploadContentReader(),
  });

  @override
  Future<PreparedUploadPayload> prepare(
    LocalUploadTask task, {
    required String objectId,
    required String versionId,
  }) async {
    final sourceFile = await _resolveSourceFile(contentReader, task);
    if (sourceFile != null) {
      final sourceContentHash = await _streamHash(sourceFile.openRead());
      final name = _fileName(task.relativePath);
      final encryptedName =
          'vaultsync-name:plain-v1:${_base64(utf8.encode(name))}';
      final metadataJson = jsonEncode({
        'format': 'vaultsync-metadata-plain-v1',
        'name': name,
        'relative_path': task.relativePath,
        'kind': 'file',
        'mtime_unix_ms': task.modifiedAt.millisecondsSinceEpoch,
        'client_size': task.sizeBytes,
        'client_content_hash': sourceContentHash,
        'object_id': objectId,
        'version_id': versionId,
      });
      return PreparedUploadPayload(
        payloadFile: sourceFile,
        payloadFileSize: await sourceFile.length(),
        payloadHash: _uploadFingerprint(
          sourceContentHash,
          encryptedName,
          metadataJson,
        ),
        sourceContentHash: sourceContentHash,
        encryptedName: encryptedName,
        metadataJson: metadataJson,
      );
    }
    final bytes = await contentReader.read(task);
    final name = _fileName(task.relativePath);
    final sourceContentHash = crypto.sha256.convert(bytes).toString();
    final encryptedName =
        'vaultsync-name:plain-v1:${_base64(utf8.encode(name))}';
    final metadataJson = jsonEncode({
      'format': 'vaultsync-metadata-plain-v1',
      'name': name,
      'relative_path': task.relativePath,
      'kind': 'file',
      'mtime_unix_ms': task.modifiedAt.millisecondsSinceEpoch,
      'client_size': task.sizeBytes,
      'client_content_hash': sourceContentHash,
      'object_id': objectId,
      'version_id': versionId,
    });
    return PreparedUploadPayload(
      bytes: bytes,
      payloadHash: _uploadFingerprint(
        sourceContentHash,
        encryptedName,
        metadataJson,
      ),
      sourceContentHash: sourceContentHash,
      encryptedName: encryptedName,
      metadataJson: metadataJson,
    );
  }

  String _fileName(String relativePath) {
    return relativePath.replaceAll('\\', '/').split('/').last;
  }

  String _base64(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
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
  final UploadCacheDirectoryProvider? cacheDirectoryProvider;

  // 这里保留原始 key bytes 用于按版本稳定派生上传 nonce，支持断点续传重试。
  // ignore: prefer_initializing_formals
  EncryptedUploadPayloadPreparer({
    required List<int> contentKeyBytes,
    required List<int> metadataKeyBytes,
    Cipher? cipher,
    this.nonceFactory,
    UploadContentReader? contentReader,
    this.cacheDirectoryProvider,
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
    final sourceFile = await _resolveSourceFile(contentReader, task);
    if (sourceFile != null &&
        cacheDirectoryProvider != null &&
        nonceFactory == null) {
      return _prepareStreaming(
        task,
        sourceFile: sourceFile,
        objectId: objectId,
        versionId: versionId,
      );
    }
    final plainBytes = await contentReader.read(task);
    final sourceContentHash = crypto.sha256.convert(plainBytes).toString();
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
    final metadata = await _metadataJson(
      task,
      objectId,
      versionId,
      sourceContentHash,
    );
    final encryptedName = await _encryptedName(task, objectId, versionId);
    final payloadBytes = _contentPayload(contentBox);
    final contentHash = crypto.sha256.convert(payloadBytes).toString();
    return PreparedUploadPayload(
      bytes: payloadBytes,
      payloadHash: _uploadFingerprint(contentHash, encryptedName, metadata),
      sourceContentHash: sourceContentHash,
      encryptedName: encryptedName,
      metadataJson: metadata,
    );
  }

  Future<PreparedUploadPayload> _prepareStreaming(
    LocalUploadTask task, {
    required File sourceFile,
    required String objectId,
    required String versionId,
  }) async {
    final sourceStat = await sourceFile.stat();
    final cacheDirectory = await cacheDirectoryProvider!();
    await cacheDirectory.create(recursive: true);
    final cacheKey = crypto.sha256
        .convert(utf8.encode('${task.id}|$objectId|$versionId'))
        .toString();
    final payloadFile = File('${cacheDirectory.path}/$cacheKey.vsenc');
    final sidecarFile = File('${cacheDirectory.path}/$cacheKey.json');
    final cached = await _loadCachedPayload(
      payloadFile: payloadFile,
      sidecarFile: sidecarFile,
      sourceStat: sourceStat,
    );
    if (cached != null) {
      final metadata = await _metadataJson(
        task,
        objectId,
        versionId,
        cached.sourceContentHash,
      );
      final encryptedName = await _encryptedName(task, objectId, versionId);
      return PreparedUploadPayload(
        payloadFile: payloadFile,
        payloadFileSize: cached.payloadSize,
        payloadHash: _uploadFingerprint(
          cached.payloadContentHash,
          encryptedName,
          metadata,
        ),
        cleanupFiles: [payloadFile, sidecarFile],
        sourceContentHash: cached.sourceContentHash,
        encryptedName: encryptedName,
        metadataJson: metadata,
      );
    }

    final sourceContentHash = await _streamHash(sourceFile.openRead());
    final contentAad = _contentAad(task, objectId, versionId);
    final nonce = _nonceFor(
      purpose: 'content',
      keyBytes: contentKeyBytes,
      aad: contentAad,
    );
    final partFile = File('${payloadFile.path}.part');
    if (await partFile.exists()) {
      await partFile.delete();
    }
    final sink = partFile.openWrite();
    Mac? contentMac;
    try {
      sink.add([..._magic.codeUnits, _algId, nonce.length, ...nonce]);
      await sink.addStream(
        cipher.encryptStream(
          sourceFile.openRead(),
          secretKey: contentKey,
          nonce: nonce,
          aad: contentAad,
          onMac: (mac) => contentMac = mac,
        ),
      );
      final mac = contentMac;
      if (mac == null) {
        throw Exception('上传内容加密未生成完整校验信息');
      }
      sink.add(mac.bytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await payloadFile.exists()) {
      await payloadFile.delete();
    }
    await partFile.rename(payloadFile.path);
    final payloadSize = await payloadFile.length();
    final payloadContentHash = await _streamHash(payloadFile.openRead());
    final sidecarPart = File('${sidecarFile.path}.part');
    await sidecarPart.writeAsString(
      jsonEncode({
        'format': 'vaultsync-upload-cache-v1',
        'source_size': sourceStat.size,
        'source_mtime_unix_ms': sourceStat.modified.millisecondsSinceEpoch,
        'source_content_hash': sourceContentHash,
        'payload_size': payloadSize,
        'payload_content_hash': payloadContentHash,
      }),
      flush: true,
    );
    if (await sidecarFile.exists()) {
      await sidecarFile.delete();
    }
    await sidecarPart.rename(sidecarFile.path);
    final metadata = await _metadataJson(
      task,
      objectId,
      versionId,
      sourceContentHash,
    );
    final encryptedName = await _encryptedName(task, objectId, versionId);
    return PreparedUploadPayload(
      payloadFile: payloadFile,
      payloadFileSize: payloadSize,
      payloadHash: _uploadFingerprint(
        payloadContentHash,
        encryptedName,
        metadata,
      ),
      cleanupFiles: [payloadFile, sidecarFile],
      sourceContentHash: sourceContentHash,
      encryptedName: encryptedName,
      metadataJson: metadata,
    );
  }

  Future<_CachedUploadPayload?> _loadCachedPayload({
    required File payloadFile,
    required File sidecarFile,
    required FileStat sourceStat,
  }) async {
    try {
      if (!await payloadFile.exists() || !await sidecarFile.exists()) {
        return null;
      }
      final json = jsonDecode(await sidecarFile.readAsString());
      if (json is! Map<String, Object?> ||
          json['format'] != 'vaultsync-upload-cache-v1' ||
          json['source_size'] != sourceStat.size ||
          json['source_mtime_unix_ms'] !=
              sourceStat.modified.millisecondsSinceEpoch ||
          json['payload_size'] != await payloadFile.length()) {
        return null;
      }
      final sourceContentHash = json['source_content_hash'];
      final payloadContentHash = json['payload_content_hash'];
      final payloadSize = json['payload_size'];
      if (sourceContentHash is! String ||
          sourceContentHash.isEmpty ||
          payloadContentHash is! String ||
          payloadContentHash.isEmpty ||
          payloadSize is! int) {
        return null;
      }
      if (await _streamHash(payloadFile.openRead()) != payloadContentHash) {
        return null;
      }
      return _CachedUploadPayload(
        sourceContentHash: sourceContentHash,
        payloadContentHash: payloadContentHash,
        payloadSize: payloadSize,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> _metadataJson(
    LocalUploadTask task,
    String objectId,
    String versionId,
    String sourceContentHash,
  ) async {
    final metadataAad = _metadataAad(task, objectId, versionId);
    final plainMetadata = jsonEncode({
      'name': _fileName(task.relativePath),
      'relative_path': task.relativePath,
      'kind': 'file',
      'mtime_unix_ms': task.modifiedAt.millisecondsSinceEpoch,
      'client_size': task.sizeBytes,
      'client_content_hash': sourceContentHash,
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

class _CachedUploadPayload {
  final String sourceContentHash;
  final String payloadContentHash;
  final int payloadSize;

  const _CachedUploadPayload({
    required this.sourceContentHash,
    required this.payloadContentHash,
    required this.payloadSize,
  });
}

Future<File?> _resolveSourceFile(
  UploadContentReader reader,
  LocalUploadTask task,
) {
  if (reader is StreamingUploadContentReader) {
    return reader.resolveFile(task);
  }
  return Future.value(null);
}

Future<String> _streamHash(Stream<List<int>> stream) async {
  return (await crypto.sha256.bind(stream).first).toString();
}

String _uploadFingerprint(
  String contentHash,
  String encryptedName,
  String metadataJson,
) {
  return crypto.sha256
      .convert(utf8.encode('$contentHash\n$encryptedName\n$metadataJson'))
      .toString();
}
