import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/encrypted_upload_payload_preparer.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test(
    'plain upload payload keeps original bytes and readable metadata',
    () async {
      final task = LocalUploadTask(
        id: 'task-1',
        syncRootId: 'root-1',
        localPath: '/tmp/a.txt',
        relativePath: 'docs/a.txt',
        sizeBytes: 5,
        modifiedAt: DateTime.utc(2026, 7, 28),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 7, 28),
        encryptionEnabled: false,
      );
      final payload = await PlainUploadPayloadPreparer(
        contentReader: _StaticContentReader([104, 101, 108, 108, 111]),
      ).prepare(task, objectId: 'obj-1', versionId: 'ver-1');

      expect(utf8.decode(payload.bytes), 'hello');
      expect(payload.encryptedName, startsWith('vaultsync-name:plain-v1:'));

      final metadata = jsonDecode(payload.metadataJson) as Map<String, Object?>;
      expect(metadata['format'], 'vaultsync-metadata-plain-v1');
      expect(metadata['name'], 'a.txt');
      expect(metadata['relative_path'], 'docs/a.txt');
    },
  );
}

class _StaticContentReader implements UploadContentReader {
  final List<int> bytes;

  const _StaticContentReader(this.bytes);

  @override
  Future<List<int>> read(LocalUploadTask task) async {
    return bytes;
  }
}
