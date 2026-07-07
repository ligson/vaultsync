import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/encrypted_download_payload_decrypter.dart';
import 'package:vaultsync_app/features/sync/local_download_writer.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test(
    'writeRemoteObject writes decrypted bytes under mapped sync root',
    () async {
      final rootDir = await Directory.systemTemp.createTemp('vaultsync_write_');
      addTearDown(() => rootDir.delete(recursive: true));
      final writer = LocalDownloadWriter(
        mappings: FakeSyncRootMappingStore([
          LocalSyncRootMapping(
            syncRootId: 'root-1',
            localPath: rootDir.path,
            encryptedPath: 'vaultsync-path:v1:root',
            cleanupPolicy: 'keep',
            archivePath: '',
          ),
        ]),
        remoteVersions: FakeRemoteVersionIndexStore(),
      );

      final result = await writer.writeRemoteObject(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        object: const DecryptedRemoteObject(
          name: 'a.jpg',
          relativePath: 'photos/a.jpg',
          metadata: {'relative_path': 'photos/a.jpg'},
          bytes: [1, 2, 3],
        ),
      );

      expect(
        result.localPath.endsWith('photos${Platform.pathSeparator}a.jpg'),
        isTrue,
      );
      expect(await File(result.localPath).readAsBytes(), [1, 2, 3]);
      expect(result.conflicted, isFalse);
    },
  );

  test('writeRemoteObject rejects path traversal', () async {
    final rootDir = await Directory.systemTemp.createTemp('vaultsync_write_');
    addTearDown(() => rootDir.delete(recursive: true));
    final writer = LocalDownloadWriter(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: rootDir.path,
          encryptedPath: 'vaultsync-path:v1:root',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]),
      remoteVersions: FakeRemoteVersionIndexStore(),
    );

    expect(
      () => writer.writeRemoteObject(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        object: const DecryptedRemoteObject(
          name: 'evil.txt',
          relativePath: '../evil.txt',
          metadata: {'relative_path': '../evil.txt'},
          bytes: [1],
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('远端路径无效'),
        ),
      ),
    );
  });

  test(
    'writeRemoteObject creates conflict copy when local file changed',
    () async {
      final rootDir = await Directory.systemTemp.createTemp('vaultsync_write_');
      addTearDown(() => rootDir.delete(recursive: true));
      final localFile = File('${rootDir.path}/photos/a.jpg');
      await localFile.parent.create(recursive: true);
      await localFile.writeAsString('local edits');
      final indexStore = FakeRemoteVersionIndexStore([
        LocalRemoteVersionIndex(
          syncRootId: 'root-1',
          objectId: 'object-1',
          versionId: 'version-1',
          relativePath: 'photos/a.jpg',
          localPath: localFile.path,
          contentHash: 'previous-remote-hash',
        ),
      ]);
      final issueStore = FakeSyncIssueStore();
      final writer = LocalDownloadWriter(
        mappings: FakeSyncRootMappingStore([
          LocalSyncRootMapping(
            syncRootId: 'root-1',
            localPath: rootDir.path,
            encryptedPath: 'vaultsync-path:v1:root',
            cleanupPolicy: 'keep',
            archivePath: '',
          ),
        ]),
        remoteVersions: indexStore,
        syncIssues: issueStore,
        conflictDeviceName: 'Alice Mac',
        now: () => DateTime.utc(2026, 6, 29, 10, 20, 30),
      );

      final result = await writer.writeRemoteObject(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-2',
        object: const DecryptedRemoteObject(
          name: 'a.jpg',
          relativePath: 'photos/a.jpg',
          metadata: {'relative_path': 'photos/a.jpg'},
          bytes: [1, 2, 3],
        ),
      );

      expect(result.conflicted, isTrue);
      expect(await localFile.readAsString(), 'local edits');
      expect(result.localPath, isNot(localFile.path));
      expect(
        result.localPath,
        contains('a (conflict Alice Mac 20260629-102030).jpg'),
      );
      expect(await File(result.localPath).readAsBytes(), [1, 2, 3]);
      expect(indexStore.saved.single.versionId, 'version-2');
      expect(indexStore.saved.single.localPath, result.localPath);
      expect(issueStore.saved.single.type, 'download_conflict');
      expect(issueStore.saved.single.localPath, result.localPath);
      expect(issueStore.saved.single.relativePath, 'photos/a.jpg');
    },
  );

  test(
    'writeRemoteObject appends index when conflict copy already exists',
    () async {
      final rootDir = await Directory.systemTemp.createTemp('vaultsync_write_');
      addTearDown(() => rootDir.delete(recursive: true));
      final localFile = File('${rootDir.path}/photos/a.jpg');
      await localFile.parent.create(recursive: true);
      await localFile.writeAsString('local edits');
      final existingConflict = File(
        '${rootDir.path}/photos/a (conflict Alice Mac 20260629-102030).jpg',
      );
      await existingConflict.writeAsString('older conflict');
      final indexStore = FakeRemoteVersionIndexStore([
        LocalRemoteVersionIndex(
          syncRootId: 'root-1',
          objectId: 'object-1',
          versionId: 'version-1',
          relativePath: 'photos/a.jpg',
          localPath: localFile.path,
          contentHash: 'previous-remote-hash',
        ),
      ]);
      final writer = LocalDownloadWriter(
        mappings: FakeSyncRootMappingStore([
          LocalSyncRootMapping(
            syncRootId: 'root-1',
            localPath: rootDir.path,
            encryptedPath: 'vaultsync-path:v1:root',
            cleanupPolicy: 'keep',
            archivePath: '',
          ),
        ]),
        remoteVersions: indexStore,
        conflictDeviceName: 'Alice Mac',
        now: () => DateTime.utc(2026, 6, 29, 10, 20, 30),
      );

      final result = await writer.writeRemoteObject(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-2',
        object: const DecryptedRemoteObject(
          name: 'a.jpg',
          relativePath: 'photos/a.jpg',
          metadata: {'relative_path': 'photos/a.jpg'},
          bytes: [1, 2, 3],
        ),
      );

      expect(result.conflicted, isTrue);
      expect(
        result.localPath,
        contains('a (conflict Alice Mac 20260629-102030 1).jpg'),
      );
      expect(await existingConflict.readAsString(), 'older conflict');
      expect(await File(result.localPath).readAsBytes(), [1, 2, 3]);
    },
  );

  test('writeRemoteObject overwrites when local file matches index', () async {
    final rootDir = await Directory.systemTemp.createTemp('vaultsync_write_');
    addTearDown(() => rootDir.delete(recursive: true));
    final localFile = File('${rootDir.path}/photos/a.jpg');
    await localFile.parent.create(recursive: true);
    await localFile.writeAsBytes([9, 9, 9]);
    final indexStore = FakeRemoteVersionIndexStore([
      LocalRemoteVersionIndex(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'photos/a.jpg',
        localPath: localFile.path,
        contentHash: sha256.convert([9, 9, 9]).toString(),
      ),
    ]);
    final writer = LocalDownloadWriter(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: rootDir.path,
          encryptedPath: 'vaultsync-path:v1:root',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]),
      remoteVersions: indexStore,
    );

    final result = await writer.writeRemoteObject(
      syncRootId: 'root-1',
      objectId: 'object-1',
      versionId: 'version-2',
      object: const DecryptedRemoteObject(
        name: 'a.jpg',
        relativePath: 'photos/a.jpg',
        metadata: {'relative_path': 'photos/a.jpg'},
        bytes: [1, 2, 3],
      ),
    );

    expect(result.conflicted, isFalse);
    expect(result.localPath, localFile.path);
    expect(await localFile.readAsBytes(), [1, 2, 3]);
  });
}

class FakeSyncRootMappingStore implements SyncRootMappingStore {
  final List<LocalSyncRootMapping> mappings;

  const FakeSyncRootMappingStore(this.mappings);

  @override
  Future<List<LocalSyncRootMapping>> loadSyncRootMappings() async => mappings;

  @override
  Future<void> saveSyncRootMapping(LocalSyncRootMapping mapping) async {}

  @override
  Future<void> saveSyncRootMappings(
    List<LocalSyncRootMapping> mappings,
  ) async {}
}

class FakeRemoteVersionIndexStore implements RemoteVersionIndexStore {
  final List<LocalRemoteVersionIndex> entries;
  final List<LocalRemoteVersionIndex> saved = [];

  FakeRemoteVersionIndexStore([this.entries = const []]);

  @override
  Future<List<LocalRemoteVersionIndex>> loadRemoteVersionIndexes() async {
    return [...entries, ...saved];
  }

  @override
  Future<void> saveRemoteVersionIndex(LocalRemoteVersionIndex entry) async {
    saved
      ..removeWhere((existing) {
        return existing.syncRootId == entry.syncRootId &&
            existing.objectId == entry.objectId;
      })
      ..add(entry);
  }

  @override
  Future<void> removeRemoteVersionIndex({
    required String syncRootId,
    required String objectId,
  }) async {}
}

class FakeSyncIssueStore implements SyncIssueStore {
  final List<LocalSyncIssue> saved = [];

  @override
  Future<List<LocalSyncIssue>> loadSyncIssues() async => saved;

  @override
  Future<void> saveSyncIssue(LocalSyncIssue issue) async {
    saved.add(issue);
  }

  @override
  Future<void> markSyncIssueResolved({required String issueId}) async {}
}
