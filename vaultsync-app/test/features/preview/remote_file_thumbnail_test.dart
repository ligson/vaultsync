import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, ECBBlockCipher, KeyParameter;
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/auth/auth_models.dart';
import 'package:vaultsync_app/features/device/device_models.dart';
import 'package:vaultsync_app/features/download/download_models.dart';
import 'package:vaultsync_app/features/download/download_service.dart';
import 'package:vaultsync_app/features/preview/remote_file_preview.dart';
import 'package:vaultsync_app/features/preview/remote_file_thumbnail.dart';
import 'package:vaultsync_app/features/sync/encrypted_download_payload_decrypter.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/wechat_dat_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads small remote image thumbnail once and reuses cache', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vaultsync_remote_thumb_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final downloads = FakeDownloadGateway();
    final loader = CachedRemoteFileThumbnailLoader(
      sessionStore: const FakeSessionStore(token: 'token-1'),
      downloads: downloads,
      decrypter: const FakeDownloadPayloadDecrypter(),
      cacheDirectoryProvider: () async => directory,
      thumbnailEncoder: (bytes) async => bytes.sublist(0, 4),
    );
    final entry = _remoteImageEntry();

    final first = await loader.load(entry);
    final second = await loader.load(entry);

    expect(first, isNotNull);
    expect(first, isNotEmpty);
    expect(second, first);
    expect(downloads.callCount, 1);
  });

  test(
    'loads extensionless WeChat image thumbnail by file signature',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vaultsync_remote_thumb_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final downloads = FakeDownloadGateway();
      final plainBytes = base64Decode(_onePixelPngBase64);
      List<int>? encodedBytes;
      final loader = CachedRemoteFileThumbnailLoader(
        sessionStore: const FakeSessionStore(token: 'token-1'),
        downloads: downloads,
        decrypter: const FakeDownloadPayloadDecrypter(
          name: '2afc89b67185a80d7',
          relativePath: 'msg/attach/00edbf/2afc89b67185a80d7',
          xorKey: 0x5a,
        ),
        cacheDirectoryProvider: () async => directory,
        thumbnailEncoder: (bytes) async {
          encodedBytes = bytes;
          return bytes.sublist(0, 4);
        },
      );

      final result = await loader.load(
        _remoteImageEntry(
          name: '2afc89b67185a80d7',
          relativePath: 'msg/attach/00edbf/2afc89b67185a80d7',
        ),
      );

      expect(result, isNotNull);
      expect(encodedBytes, orderedEquals(plainBytes));
      expect(downloads.callCount, 1);
    },
  );

  test('loads WeChat v2 dat thumbnail when image key is available', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vaultsync_remote_thumb_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final aesKey = List<int>.generate(16, (index) => index + 1);
    const xorKey = 0x3a;
    final downloads = FakeDownloadGateway();
    List<int>? encodedBytes;
    final loader = CachedRemoteFileThumbnailLoader(
      sessionStore: const FakeSessionStore(token: 'token-1'),
      downloads: downloads,
      decrypter: FakeDownloadPayloadDecrypter(
        name: '2afc89b67185a80d7.dat',
        relativePath: 'msg/attach/00edbf/2afc89b67185a80d7.dat',
        bytes: _wechatDatV2JpegBytes(aesKey: aesKey, xorKey: xorKey),
      ),
      cacheDirectoryProvider: () async => directory,
      wechatDatV2ImageKeys: FakeWechatDatV2ImageKeyProvider(
        WechatDatV2ImageKey(aesKey: aesKey, xorKey: xorKey),
      ),
      thumbnailEncoder: (bytes) async {
        encodedBytes = bytes;
        return bytes.sublist(0, 4);
      },
    );

    final result = await loader.load(
      _remoteImageEntry(
        name: '2afc89b67185a80d7.dat',
        relativePath: 'msg/attach/00edbf/2afc89b67185a80d7.dat',
      ),
    );

    expect(result, isNotNull);
    expect(encodedBytes, orderedEquals(_jpegBytes));
    expect(downloads.callCount, 1);
  });

  test('does not auto download large remote image for thumbnail', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vaultsync_remote_thumb_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final downloads = FakeDownloadGateway();
    final loader = CachedRemoteFileThumbnailLoader(
      sessionStore: const FakeSessionStore(token: 'token-1'),
      downloads: downloads,
      decrypter: const FakeDownloadPayloadDecrypter(),
      cacheDirectoryProvider: () async => directory,
    );

    final result = await loader.load(
      _remoteImageEntry(sizeBytes: 8 * 1024 * 1024),
    );

    expect(result, isNull);
    expect(downloads.callCount, 0);
  });
}

RemoteBackupEntry _remoteImageEntry({
  int sizeBytes = 128,
  String name = 'photo.png',
  String? relativePath,
}) {
  return RemoteBackupEntry(
    syncRootId: 'root-1',
    objectId: 'object-1',
    versionId: 'version-1',
    name: name,
    relativePath: relativePath ?? name,
    sizeBytes: sizeBytes,
    updatedAt: '2026-08-11T09:00:00Z',
    encryptedName: 'enc:photo.png',
    metadataJson: '{}',
    contentHash: 'cipher-hash-1',
    clientContentHash: 'plain-hash-1',
  );
}

class FakeSessionStore implements SessionStore {
  final String? token;

  const FakeSessionStore({this.token});

  @override
  Future<String?> loadAuthToken() async => token;

  @override
  Future<String?> loadAuthExpiresAt() async => '2999-01-01T00:00:00Z';

  @override
  Future<String?> loadDeviceId() async => 'device-1';

  @override
  Future<void> saveAuthSession(AuthSession session) async {}

  @override
  Future<void> saveDevice(RegisteredDevice device) async {}
}

class FakeDownloadGateway implements DownloadGateway {
  int callCount = 0;

  @override
  Future<DownloadedObject> downloadCiphertext({
    required String token,
    required String versionId,
    required String objectId,
    required String syncRootId,
    required String encryptedName,
  }) async {
    callCount += 1;
    return DownloadedObject(
      versionId: versionId,
      objectId: objectId,
      syncRootId: syncRootId,
      encryptedName: encryptedName,
      bytes: [1, 2, 3],
    );
  }
}

class FakeDownloadPayloadDecrypter implements DownloadPayloadDecrypter {
  final String name;
  final String relativePath;
  final int? xorKey;
  final List<int>? bytes;

  const FakeDownloadPayloadDecrypter({
    this.name = 'photo.png',
    this.relativePath = 'photo.png',
    this.xorKey,
    this.bytes,
  });

  @override
  Future<DecryptedRemoteObject> decrypt({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required String encryptedName,
    required String metadataJson,
    required List<int> payloadBytes,
  }) async {
    final plainBytes = bytes ?? base64Decode(_onePixelPngBase64);
    return DecryptedRemoteObject(
      name: name,
      relativePath: relativePath,
      metadata: const {},
      bytes: xorKey == null
          ? plainBytes
          : [for (final byte in plainBytes) byte ^ xorKey!],
    );
  }
}

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/axl3ToAAAAASUVORK5CYII=';

const _jpegBytes = [
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
  0xff,
  0xd9,
];

List<int> _wechatDatV2JpegBytes({
  required List<int> aesKey,
  required int xorKey,
}) {
  final encryptedPrefix = _encryptAesEcb([
    ..._jpegBytes.take(10),
    ...List<int>.filled(6, 6),
  ], aesKey);
  final tail = _jpegBytes.sublist(10);
  return [
    0x07,
    0x08,
    0x56,
    0x32,
    0x08,
    0x07,
    ..._uint32LittleEndian(10),
    ..._uint32LittleEndian(tail.length),
    0x01,
    ...encryptedPrefix,
    for (final byte in tail) byte ^ xorKey,
  ];
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

class FakeWechatDatV2ImageKeyProvider implements WechatDatV2ImageKeyProvider {
  final WechatDatV2ImageKey? key;

  const FakeWechatDatV2ImageKeyProvider(this.key);

  @override
  Future<WechatDatV2ImageKey?> loadImageKey({
    required String name,
    required String relativePath,
    required List<int> bytes,
  }) async {
    return key;
  }
}
