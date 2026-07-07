import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/local_remote_delete_handler.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('handleRemoteDelete ignores unknown remote object', () async {
    final store = FakeRemoteVersionIndexStore([]);
    final issues = FakeSyncIssueStore();
    final handler = LocalRemoteDeleteHandler(
      remoteVersions: store,
      syncIssues: issues,
    );

    final result = await handler.handleRemoteDelete(
      syncRootId: 'root-1',
      objectId: 'object-1',
    );

    expect(result.deleted, isFalse);
    expect(result.blockedLocalChange, isFalse);
    expect(store.removedObjectIds, isEmpty);
  });

  test('handleRemoteDelete deletes unchanged local file and index', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_delete_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.jpg');
    await file.writeAsBytes([1, 2, 3]);
    final store = FakeRemoteVersionIndexStore([
      LocalRemoteVersionIndex(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'a.jpg',
        localPath: file.path,
        contentHash: sha256.convert([1, 2, 3]).toString(),
      ),
    ]);
    final handler = LocalRemoteDeleteHandler(remoteVersions: store);

    final result = await handler.handleRemoteDelete(
      syncRootId: 'root-1',
      objectId: 'object-1',
    );

    expect(result.deleted, isTrue);
    expect(result.blockedLocalChange, isFalse);
    expect(await file.exists(), isFalse);
    expect(store.removedObjectIds, ['object-1']);
  });

  test('handleRemoteDelete removes index when local file is missing', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_delete_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/missing.jpg');
    final store = FakeRemoteVersionIndexStore([
      LocalRemoteVersionIndex(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'missing.jpg',
        localPath: file.path,
        contentHash: 'previous-remote-hash',
      ),
    ]);
    final handler = LocalRemoteDeleteHandler(remoteVersions: store);

    final result = await handler.handleRemoteDelete(
      syncRootId: 'root-1',
      objectId: 'object-1',
    );

    expect(result.deleted, isFalse);
    expect(result.blockedLocalChange, isFalse);
    expect(store.removedObjectIds, ['object-1']);
  });

  test('handleRemoteDelete keeps changed local file', () async {
    final dir = await Directory.systemTemp.createTemp('vaultsync_delete_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.jpg');
    await file.writeAsString('local edits');
    final store = FakeRemoteVersionIndexStore([
      LocalRemoteVersionIndex(
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-1',
        relativePath: 'a.jpg',
        localPath: file.path,
        contentHash: 'previous-remote-hash',
      ),
    ]);
    final issues = FakeSyncIssueStore();
    final handler = LocalRemoteDeleteHandler(
      remoteVersions: store,
      syncIssues: issues,
    );

    final result = await handler.handleRemoteDelete(
      syncRootId: 'root-1',
      objectId: 'object-1',
    );

    expect(result.deleted, isFalse);
    expect(result.blockedLocalChange, isTrue);
    expect(await file.readAsString(), 'local edits');
    expect(store.removedObjectIds, isEmpty);
    expect(issues.saved.single.type, 'remote_delete_blocked');
    expect(issues.saved.single.localPath, file.path);
    expect(issues.saved.single.relativePath, 'a.jpg');
  });
}

class FakeRemoteVersionIndexStore implements RemoteVersionIndexStore {
  final List<LocalRemoteVersionIndex> entries;
  final List<String> removedObjectIds = [];

  FakeRemoteVersionIndexStore(this.entries);

  @override
  Future<List<LocalRemoteVersionIndex>> loadRemoteVersionIndexes() async {
    return entries;
  }

  @override
  Future<void> saveRemoteVersionIndex(LocalRemoteVersionIndex entry) async {}

  @override
  Future<void> removeRemoteVersionIndex({
    required String syncRootId,
    required String objectId,
  }) async {
    removedObjectIds.add(objectId);
  }
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
