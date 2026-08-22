import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, ECBBlockCipher, KeyParameter;
import 'package:vaultsync_app/features/sync/encrypted_upload_payload_preparer.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/wechat_dat_decoder.dart';

void main() {
  test('prepare encrypts file content and metadata for upload', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_encrypt_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.jpg');
    await file.writeAsString('plain photo bytes');

    final preparer = EncryptedUploadPayloadPreparer(
      contentKeyBytes: List<int>.filled(32, 1),
      metadataKeyBytes: List<int>.filled(32, 2),
      nonceFactory: SequenceNonceFactory(),
    );
    final task = LocalUploadTask(
      id: 'root-1:a.jpg',
      syncRootId: 'root-1',
      localPath: file.path,
      relativePath: 'a.jpg',
      sizeBytes: await file.length(),
      modifiedAt: DateTime.utc(2026, 6, 27, 9),
      status: 'pending',
      attempts: 0,
      createdAt: DateTime.utc(2026, 6, 27, 10),
    );

    final payload = await preparer.prepare(
      task,
      objectId: 'object-1',
      versionId: 'version-1',
    );

    expect(payload.bytes.take(8), 'VSENC001'.codeUnits);
    expect(payload.bytes, isNot(containsAll('plain photo bytes'.codeUnits)));
    expect(payload.encryptedName, startsWith('vaultsync-name:v1:'));
    expect(payload.encryptedName, isNot(contains('a.jpg')));
    expect(payload.metadataJson, isNot(contains('a.jpg')));
    expect(payload.metadataJson, isNot(contains(payload.sourceContentHash)));
    expect(
      payload.sourceContentHash,
      sha256.convert(utf8.encode('plain photo bytes')).toString(),
    );

    final metadata = jsonDecode(payload.metadataJson) as Map<String, Object?>;
    expect(metadata['format'], 'vaultsync-metadata-v1');
    expect(metadata['alg'], 'XChaCha20-Poly1305');

    final decryptedContent = await _decryptContent(payload.bytes);
    expect(utf8.decode(decryptedContent), 'plain photo bytes');
    final decryptedMetadata = await _decryptMetadata(metadata);
    expect(decryptedMetadata['name'], 'a.jpg');
    expect(decryptedMetadata['relative_path'], 'a.jpg');
    expect(decryptedMetadata['client_size'], 17);
    expect(decryptedMetadata['client_content_hash'], payload.sourceContentHash);
    final decryptedName = await _decryptName(payload.encryptedName);
    expect(decryptedName, 'a.jpg');
  });

  test(
    'prepare produces stable ciphertext for the same file version',
    () async {
      final dir = await Directory.systemTemp.createTemp('vaultsync_encrypt_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.jpg');
      await file.writeAsString('plain photo bytes');

      final preparer = EncryptedUploadPayloadPreparer(
        contentKeyBytes: List<int>.filled(32, 1),
        metadataKeyBytes: List<int>.filled(32, 2),
      );
      final task = LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: file.path,
        relativePath: 'a.jpg',
        sizeBytes: await file.length(),
        modifiedAt: DateTime.utc(2026, 6, 27, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      );

      final first = await preparer.prepare(
        task,
        objectId: 'object-1',
        versionId: 'version-1',
      );
      final second = await preparer.prepare(
        task,
        objectId: 'object-1',
        versionId: 'version-1',
      );
      final nextVersion = await preparer.prepare(
        task,
        objectId: 'object-1',
        versionId: 'version-2',
      );

      expect(second.bytes, first.bytes);
      expect(second.metadataJson, first.metadataJson);
      expect(second.encryptedName, first.encryptedName);
      expect(nextVersion.bytes, isNot(first.bytes));
    },
  );

  test('prepare can read media asset content', () async {
    final preparer = EncryptedUploadPayloadPreparer(
      contentKeyBytes: List<int>.filled(32, 1),
      metadataKeyBytes: List<int>.filled(32, 2),
      contentReader: FakeUploadContentReader([1, 2, 3]),
    );

    final payload = await preparer.prepare(
      LocalUploadTask(
        id: 'root-1:asset-1',
        syncRootId: 'root-1',
        localPath: '',
        relativePath: '相册/2026/07/a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 7, 3, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7, 3, 10),
        sourceType: 'media_asset',
        assetId: 'asset-1',
        assetMediaType: 'image',
      ),
      objectId: 'object-1',
      versionId: 'version-1',
    );

    expect(payload.bytes.take(8), 'VSENC001'.codeUnits);
  });

  test('prepare stores plaintext hash in plain metadata', () async {
    final preparer = PlainUploadPayloadPreparer(
      contentReader: FakeUploadContentReader(const [1, 2, 3]),
    );
    final payload = await preparer.prepare(
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/local/a.jpg',
        relativePath: 'photos/a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
        encryptionEnabled: false,
      ),
      objectId: 'object-1',
      versionId: 'version-1',
    );

    final metadata = jsonDecode(payload.metadataJson) as Map<String, Object?>;
    expect(metadata['client_content_hash'], payload.sourceContentHash);
    expect(
      payload.sourceContentHash,
      sha256.convert(const [1, 2, 3]).toString(),
    );
  });

  test('streaming prepare keeps VSENC001 bytes and reuses cache', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_stream_');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/large.bin');
    await source.writeAsBytes(List<int>.generate(128 * 1024, (i) => i % 251));
    final cache = Directory('${dir.path}/cache');
    final task = LocalUploadTask(
      id: 'root-1:large.bin',
      syncRootId: 'root-1',
      localPath: source.path,
      relativePath: 'large.bin',
      sizeBytes: await source.length(),
      modifiedAt: (await source.stat()).modified,
      status: 'pending',
      attempts: 0,
      createdAt: DateTime.utc(2026, 8, 4),
    );
    final memoryPreparer = EncryptedUploadPayloadPreparer(
      contentKeyBytes: List<int>.filled(32, 1),
      metadataKeyBytes: List<int>.filled(32, 2),
    );
    final streamingPreparer = EncryptedUploadPayloadPreparer(
      contentKeyBytes: List<int>.filled(32, 1),
      metadataKeyBytes: List<int>.filled(32, 2),
      cacheDirectoryProvider: () async => cache,
    );

    final expected = await memoryPreparer.prepare(
      task,
      objectId: 'object-1',
      versionId: 'version-1',
    );
    final first = await streamingPreparer.prepare(
      task,
      objectId: 'object-1',
      versionId: 'version-1',
    );
    final firstModifiedAt = (await first.payloadFile!.stat()).modified;
    final second = await streamingPreparer.prepare(
      task,
      objectId: 'object-1',
      versionId: 'version-1',
    );

    expect(first.bytes, isEmpty);
    expect(await first.readAll(), expected.bytes);
    expect(first.payloadHash, expected.payloadHash);
    expect(first.metadataJson, expected.metadataJson);
    expect(first.encryptedName, expected.encryptedName);
    expect(await first.readRange(7, 39), expected.bytes.sublist(7, 39));
    expect((await second.payloadFile!.stat()).modified, firstModifiedAt);
    expect(await second.readAll(), expected.bytes);

    await second.cleanupAfterSuccess();
    expect(await second.payloadFile!.exists(), isFalse);
  });

  test(
    'plain file prepare streams without keeping all bytes in memory',
    () async {
      final dir = await Directory.systemTemp.createTemp('vaultsync_plain_');
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/plain.bin');
      await source.writeAsBytes(const [1, 2, 3, 4]);
      final payload = await const PlainUploadPayloadPreparer().prepare(
        LocalUploadTask(
          id: 'root-1:plain.bin',
          syncRootId: 'root-1',
          localPath: source.path,
          relativePath: 'plain.bin',
          sizeBytes: 4,
          modifiedAt: DateTime.utc(2026, 8, 4),
          status: 'pending',
          attempts: 0,
          createdAt: DateTime.utc(2026, 8, 4),
          encryptionEnabled: false,
        ),
        objectId: 'object-1',
        versionId: 'version-1',
      );

      expect(payload.bytes, isEmpty);
      expect(payload.payloadFile?.path, source.path);
      expect(await payload.readRange(1, 3), [2, 3]);
    },
  );

  test(
    'WechatDatUploadContentReader decodes legacy dat bytes before upload',
    () async {
      const decoded = [
        0xff,
        0xd8,
        0xff,
        0xe0,
        0x00,
        0x10,
        0x4a,
        0x46,
        0x49,
        0x46,
      ];
      const key = 0x33;
      final reader = WechatDatUploadContentReader(
        fileReader: FakeUploadContentReader([
          for (final byte in decoded) byte ^ key,
        ]),
      );
      final bytes = await reader.read(
        LocalUploadTask(
          id: 'wechat-root:image/photo.jpg',
          syncRootId: 'wechat-root',
          localPath: '/tmp/photo.dat',
          relativePath: 'image/photo.jpg',
          sizeBytes: decoded.length,
          modifiedAt: DateTime.utc(2026, 8, 20),
          status: 'pending',
          attempts: 0,
          createdAt: DateTime.utc(2026, 8, 20),
          sourceType: 'wechat_file',
        ),
      );
      expect(bytes, decoded);
    },
  );

  test('decodeWechatDatV2Image decodes AES and XOR protected image bytes', () {
    final aesKey = List<int>.generate(16, (index) => index + 1);
    const xorKey = 0x3a;
    const plainPrefix = [
      0xff,
      0xd8,
      0xff,
      0xe0,
      0x00,
      0x10,
      0x4a,
      0x46,
      0x49,
      0x46,
    ];
    const plainTail = [0xff, 0xd9];
    final encryptedPrefix = _encryptAesEcb([
      ...plainPrefix,
      ...List<int>.filled(6, 6),
    ], aesKey);
    final datBytes = <int>[
      0x07,
      0x08,
      0x56,
      0x32,
      0x08,
      0x07,
      ..._uint32LittleEndian(plainPrefix.length),
      ..._uint32LittleEndian(plainTail.length),
      0x01,
      ...encryptedPrefix,
      for (final byte in plainTail) byte ^ xorKey,
    ];

    final decoded = decodeWechatDatV2Image(
      datBytes,
      WechatDatV2ImageKey(aesKey: aesKey, xorKey: xorKey),
    );

    expect(decoded?.extension, 'jpg');
    expect(decoded?.bytes, orderedEquals([...plainPrefix, ...plainTail]));
    expect(inferWechatDatV2JpegTailXorKey(datBytes), xorKey);
  });
}

Future<List<int>> _decryptContent(List<int> payload) async {
  final cipher = Xchacha20.poly1305Aead();
  final nonce = payload.sublist(10, 34);
  final ciphertextAndMac = payload.sublist(34);
  final macLength = cipher.macAlgorithm.macLength;
  final ciphertext = ciphertextAndMac.sublist(
    0,
    ciphertextAndMac.length - macLength,
  );
  final mac = ciphertextAndMac.sublist(ciphertextAndMac.length - macLength);
  return cipher.decrypt(
    SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
    secretKey: SecretKey(List<int>.filled(32, 1)),
    aad: utf8.encode('vaultsync/v1/content|root-1|object-1|version-1'),
  );
}

Future<Map<String, Object?>> _decryptMetadata(
  Map<String, Object?> metadata,
) async {
  final nonce = _base64UrlDecode(metadata['nonce']! as String);
  final ciphertextAndMac = _base64UrlDecode(metadata['ciphertext']! as String);
  final decrypted = await _decryptBox(
    nonce: nonce,
    ciphertextAndMac: ciphertextAndMac,
    secretKey: SecretKey(List<int>.filled(32, 2)),
    aad: utf8.encode('vaultsync/v1/metadata|root-1|object-1|version-1'),
  );
  return jsonDecode(utf8.decode(decrypted)) as Map<String, Object?>;
}

Future<String> _decryptName(String encryptedName) async {
  final encoded = encryptedName.substring('vaultsync-name:v1:'.length);
  final bytes = _base64UrlDecode(encoded);
  final decrypted = await _decryptBox(
    nonce: bytes.sublist(0, 24),
    ciphertextAndMac: bytes.sublist(24),
    secretKey: SecretKey(List<int>.filled(32, 2)),
    aad: utf8.encode('vaultsync/v1/name|root-1|object-1|version-1'),
  );
  return utf8.decode(decrypted);
}

Future<List<int>> _decryptBox({
  required List<int> nonce,
  required List<int> ciphertextAndMac,
  required SecretKey secretKey,
  required List<int> aad,
}) async {
  final cipher = Xchacha20.poly1305Aead();
  final macLength = cipher.macAlgorithm.macLength;
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

List<int> _encryptAesEcb(List<int> bytes, List<int> aesKey) {
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(aesKey)));
  final input = Uint8List.fromList(bytes);
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += cipher.blockSize) {
    cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

List<int> _uint32LittleEndian(int value) {
  return [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];
}

class SequenceNonceFactory implements UploadNonceFactory {
  var nextValue = 1;

  @override
  List<int> nextNonce() {
    return List<int>.filled(24, nextValue++);
  }
}

class FakeUploadContentReader implements UploadContentReader {
  final List<int> bytes;

  FakeUploadContentReader(this.bytes);

  @override
  Future<List<int>> read(LocalUploadTask task) async => bytes;
}
