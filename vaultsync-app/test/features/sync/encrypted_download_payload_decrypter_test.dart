import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/encrypted_download_payload_decrypter.dart';
import 'package:vaultsync_app/features/sync/encrypted_upload_payload_preparer.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('decrypt restores content metadata and encrypted name', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_decrypt_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/photos/a.jpg');
    await file.parent.create(recursive: true);
    await file.writeAsString('plain photo bytes');

    final preparer = EncryptedUploadPayloadPreparer(
      contentKeyBytes: List<int>.filled(32, 1),
      metadataKeyBytes: List<int>.filled(32, 2),
      nonceFactory: SequenceNonceFactory(),
    );
    final task = LocalUploadTask(
      id: 'root-1:photos/a.jpg',
      syncRootId: 'root-1',
      localPath: file.path,
      relativePath: 'photos/a.jpg',
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

    final decrypter = EncryptedDownloadPayloadDecrypter(
      contentKeyBytes: List<int>.filled(32, 1),
      metadataKeyBytes: List<int>.filled(32, 2),
    );

    final object = await decrypter.decrypt(
      syncRootId: 'root-1',
      objectId: 'object-1',
      versionId: 'version-1',
      encryptedName: payload.encryptedName,
      metadataJson: payload.metadataJson,
      payloadBytes: payload.bytes,
    );

    expect(utf8.decode(object.bytes), 'plain photo bytes');
    expect(object.name, 'a.jpg');
    expect(object.relativePath, 'photos/a.jpg');
    expect(object.metadata['client_size'], 17);
  });

  test('decrypt rejects invalid content magic', () async {
    final decrypter = EncryptedDownloadPayloadDecrypter(
      contentKeyBytes: List<int>.filled(32, 1),
      metadataKeyBytes: List<int>.filled(32, 2),
    );

    expect(
      () => decrypter.decrypt(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        encryptedName: 'vaultsync-name:v1:bad',
        metadataJson: '{}',
        payloadBytes: const [1, 2, 3],
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('密文格式无效'),
        ),
      ),
    );
  });
}

class SequenceNonceFactory implements UploadNonceFactory {
  var nextValue = 1;

  @override
  List<int> nextNonce() {
    return List<int>.filled(24, nextValue++);
  }
}
