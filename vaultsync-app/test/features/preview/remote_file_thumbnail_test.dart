import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/auth/auth_models.dart';
import 'package:vaultsync_app/features/device/device_models.dart';
import 'package:vaultsync_app/features/download/download_models.dart';
import 'package:vaultsync_app/features/download/download_service.dart';
import 'package:vaultsync_app/features/preview/remote_file_thumbnail.dart';
import 'package:vaultsync_app/features/sync/encrypted_download_payload_decrypter.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

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

RemoteBackupEntry _remoteImageEntry({int sizeBytes = 128}) {
  return RemoteBackupEntry(
    syncRootId: 'root-1',
    objectId: 'object-1',
    versionId: 'version-1',
    name: 'photo.png',
    relativePath: 'photo.png',
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
  const FakeDownloadPayloadDecrypter();

  @override
  Future<DecryptedRemoteObject> decrypt({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required String encryptedName,
    required String metadataJson,
    required List<int> payloadBytes,
  }) async {
    return DecryptedRemoteObject(
      name: 'photo.png',
      relativePath: 'photo.png',
      metadata: const {},
      bytes: base64Decode(_onePixelPngBase64),
    );
  }
}

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/axl3ToAAAAASUVORK5CYII=';
