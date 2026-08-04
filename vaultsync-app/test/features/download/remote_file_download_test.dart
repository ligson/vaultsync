import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/download/download_models.dart';
import 'package:vaultsync_app/features/download/download_service.dart';
import 'package:vaultsync_app/features/download/remote_file_download.dart';
import 'package:vaultsync_app/features/sync/encrypted_download_payload_decrypter.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('downloads and decrypts the selected remote file', () async {
    final downloads = _FakeDownloadGateway();
    final decrypter = _FakeDownloadPayloadDecrypter();
    final loader = RemoteFileDownloadLoader(
      downloads: downloads,
      decrypter: decrypter,
    );

    final data = await loader.load(token: 'token-1', entry: _entry());

    expect(data.name, 'report.bin');
    expect(data.bytes, orderedEquals([7, 8, 9]));
    expect(downloads.token, 'token-1');
    expect(downloads.versionId, 'version-1');
    expect(decrypter.metadataJson, '{"format":"test"}');
    expect(decrypter.payloadBytes, orderedEquals([1, 2, 3]));
  });

  test('rejects a remote file without complete payload metadata', () async {
    final downloads = _FakeDownloadGateway();
    final loader = RemoteFileDownloadLoader(
      downloads: downloads,
      decrypter: _FakeDownloadPayloadDecrypter(),
    );

    await expectLater(
      loader.load(
        token: 'token-1',
        entry: _entry(metadataJson: ''),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('服务器未返回完整文件信息'),
        ),
      ),
    );
    expect(downloads.callCount, 0);
  });
}

RemoteBackupEntry _entry({String metadataJson = '{"format":"test"}'}) {
  return RemoteBackupEntry(
    syncRootId: 'root-1',
    objectId: 'object-1',
    versionId: 'version-1',
    name: 'report.bin',
    relativePath: 'reports/report.bin',
    sizeBytes: 3,
    updatedAt: '2026-08-04T00:00:00Z',
    encryptedName: 'encrypted-report',
    metadataJson: metadataJson,
  );
}

class _FakeDownloadGateway implements DownloadGateway {
  var callCount = 0;
  String? token;
  String? versionId;

  @override
  Future<DownloadedObject> downloadCiphertext({
    required String token,
    required String versionId,
    required String objectId,
    required String syncRootId,
    required String encryptedName,
  }) async {
    callCount += 1;
    this.token = token;
    this.versionId = versionId;
    return DownloadedObject(
      versionId: versionId,
      objectId: objectId,
      syncRootId: syncRootId,
      encryptedName: encryptedName,
      bytes: const [1, 2, 3],
    );
  }
}

class _FakeDownloadPayloadDecrypter implements DownloadPayloadDecrypter {
  String? metadataJson;
  List<int>? payloadBytes;

  @override
  Future<DecryptedRemoteObject> decrypt({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required String encryptedName,
    required String metadataJson,
    required List<int> payloadBytes,
  }) async {
    this.metadataJson = metadataJson;
    this.payloadBytes = payloadBytes;
    return const DecryptedRemoteObject(
      name: 'report.bin',
      relativePath: 'reports/report.bin',
      metadata: {},
      bytes: [7, 8, 9],
    );
  }
}
