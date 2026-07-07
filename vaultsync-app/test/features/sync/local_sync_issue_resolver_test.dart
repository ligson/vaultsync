import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/local_sync_issue_resolver.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('enqueueConflictForUpload creates pending upload task', () async {
    final rootDir = await Directory.systemTemp.createTemp(
      'vaultsync_issue_upload_',
    );
    addTearDown(() => rootDir.delete(recursive: true));
    final conflictFile = File(
      '${rootDir.path}/photos/a (conflict Alice Mac 20260629-102030).jpg',
    );
    await conflictFile.parent.create(recursive: true);
    await conflictFile.writeAsBytes([1, 2, 3, 4]);
    final uploadTasks = FakeUploadTaskStore();
    final issues = FakeSyncIssueStore([
      LocalSyncIssue(
        id: 'download_conflict:root-1:object-1',
        type: 'download_conflict',
        syncRootId: 'root-1',
        objectId: 'object-1',
        versionId: 'version-2',
        relativePath: 'photos/a.jpg',
        localPath: conflictFile.path,
        message: '远端更新已保存为冲突副本',
        status: 'open',
        createdAt: DateTime.utc(2026, 6, 29),
      ),
    ]);
    final resolver = LocalSyncIssueResolver(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: rootDir.path,
          encryptedPath: 'vaultsync-path:v1:root',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]),
      uploadTasks: uploadTasks,
      syncIssues: issues,
      now: () => DateTime.utc(2026, 6, 29, 12),
    );

    final task = await resolver.enqueueConflictForUpload(issues.issues.single);

    expect(task.status, 'pending');
    expect(task.syncRootId, 'root-1');
    expect(
      task.relativePath,
      'photos/a (conflict Alice Mac 20260629-102030).jpg',
    );
    expect(task.localPath, conflictFile.path);
    expect(task.sizeBytes, 4);
    expect(uploadTasks.saved.single.id, task.id);
    expect(issues.issues.single.status, 'resolved');
  });

  test('enqueueConflictForUpload rejects missing conflict file', () async {
    final resolver = LocalSyncIssueResolver(
      mappings: const FakeSyncRootMappingStore([]),
      uploadTasks: FakeUploadTaskStore(),
      syncIssues: FakeSyncIssueStore([]),
    );

    expect(
      () => resolver.enqueueConflictForUpload(
        LocalSyncIssue(
          id: 'download_conflict:root-1:object-1',
          type: 'download_conflict',
          syncRootId: 'root-1',
          objectId: 'object-1',
          versionId: 'version-2',
          relativePath: 'photos/a.jpg',
          localPath: '/missing/a.jpg',
          message: '远端更新已保存为冲突副本',
          status: 'open',
          createdAt: DateTime.utc(2026, 6, 29),
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('冲突副本不存在'),
        ),
      ),
    );
  });

  test('enqueueConflictForUpload rejects file outside sync root', () async {
    final rootDir = await Directory.systemTemp.createTemp(
      'vaultsync_issue_upload_',
    );
    final outsideDir = await Directory.systemTemp.createTemp(
      'vaultsync_issue_outside_',
    );
    addTearDown(() => rootDir.delete(recursive: true));
    addTearDown(() => outsideDir.delete(recursive: true));
    final conflictFile = File('${outsideDir.path}/a.jpg');
    await conflictFile.writeAsBytes([1]);
    final resolver = LocalSyncIssueResolver(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: rootDir.path,
          encryptedPath: 'vaultsync-path:v1:root',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]),
      uploadTasks: FakeUploadTaskStore(),
      syncIssues: FakeSyncIssueStore([]),
    );

    expect(
      () => resolver.enqueueConflictForUpload(
        LocalSyncIssue(
          id: 'download_conflict:root-1:object-1',
          type: 'download_conflict',
          syncRootId: 'root-1',
          objectId: 'object-1',
          versionId: 'version-2',
          relativePath: 'a.jpg',
          localPath: conflictFile.path,
          message: '远端更新已保存为冲突副本',
          status: 'open',
          createdAt: DateTime.utc(2026, 6, 29),
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('冲突副本不在本地同步目录内'),
        ),
      ),
    );
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

class FakeUploadTaskStore implements UploadTaskStore {
  final List<LocalUploadTask> saved = [];

  @override
  Future<List<LocalUploadTask>> loadUploadTasks() async => saved;

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {
    saved
      ..clear()
      ..addAll(tasks);
  }
}

class FakeSyncIssueStore implements SyncIssueStore {
  final List<LocalSyncIssue> issues;

  FakeSyncIssueStore(this.issues);

  @override
  Future<List<LocalSyncIssue>> loadSyncIssues() async => issues;

  @override
  Future<void> saveSyncIssue(LocalSyncIssue issue) async {
    issues.add(issue);
  }

  @override
  Future<void> markSyncIssueResolved({required String issueId}) async {
    final index = issues.indexWhere((issue) => issue.id == issueId);
    final issue = issues[index];
    issues[index] = LocalSyncIssue(
      id: issue.id,
      type: issue.type,
      syncRootId: issue.syncRootId,
      objectId: issue.objectId,
      versionId: issue.versionId,
      relativePath: issue.relativePath,
      localPath: issue.localPath,
      message: issue.message,
      status: 'resolved',
      createdAt: issue.createdAt,
    );
  }
}
