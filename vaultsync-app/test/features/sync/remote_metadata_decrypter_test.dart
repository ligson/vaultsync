import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/encrypted_upload_payload_preparer.dart';
import 'package:vaultsync_app/features/sync/remote_metadata_decrypter.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('decrypt restores remote backup name and relative path', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_remote_meta_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/photos/a.jpg');
    await file.parent.create(recursive: true);
    await file.writeAsString('plain photo bytes');

    final preparer = EncryptedUploadPayloadPreparer(
      contentKeyBytes: List<int>.filled(32, 1),
      metadataKeyBytes: List<int>.filled(32, 2),
      nonceFactory: SequenceNonceFactory(),
    );
    final payload = await preparer.prepare(
      LocalUploadTask(
        id: 'root-1:photos/a.jpg',
        syncRootId: 'root-1',
        localPath: file.path,
        relativePath: 'photos/a.jpg',
        sizeBytes: await file.length(),
        modifiedAt: DateTime.utc(2026, 7, 1, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7, 1, 10),
      ),
      objectId: 'object-1',
      versionId: 'version-1',
    );
    final decrypter = XChaCha20RemoteMetadataDecrypter(
      metadataKeyBytes: List<int>.filled(32, 2),
    );

    final entry = await decrypter.decrypt(
      RemoteBackupObject(
        cursorValue: 1,
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        encryptedName: payload.encryptedName,
        contentHash: 'sha256:abc',
        sizeBytes: payload.bytes.length,
        metadataJson: payload.metadataJson,
        updatedAt: '2026-07-01T10:00:00Z',
      ),
    );

    expect(entry.decryptable, isTrue);
    expect(entry.name, 'a.jpg');
    expect(entry.relativePath, 'photos/a.jpg');
    expect(entry.sizeBytes, payload.bytes.length);
  });

  test('decrypt returns placeholder for invalid metadata', () async {
    final decrypter = XChaCha20RemoteMetadataDecrypter(
      metadataKeyBytes: List<int>.filled(32, 2),
    );

    final entry = await decrypter.decrypt(
      const RemoteBackupObject(
        cursorValue: 1,
        syncRootId: 'root-1',
        objectId: 'object-abcdef',
        versionId: 'version-1',
        encryptedName: 'bad-name',
        contentHash: 'sha256:abc',
        sizeBytes: 3,
        metadataJson: '{}',
        updatedAt: '2026-07-01T10:00:00Z',
      ),
    );

    expect(entry.decryptable, isFalse);
    expect(entry.name, '无法解密的备份对象');
    expect(entry.relativePath, '无法解密的备份对象 object-a');
  });
}

class SequenceNonceFactory implements UploadNonceFactory {
  var nextValue = 1;

  @override
  List<int> nextNonce() {
    return List<int>.filled(24, nextValue++);
  }
}
