import 'dart:io';

import '../../core/storage/app_storage.dart';
import 'local_upload_planner.dart';
import 'sync_models.dart';

class LocalSyncIssueResolver {
  final SyncRootMappingStore mappings;
  final UploadTaskStore uploadTasks;
  final SyncIssueStore syncIssues;
  final DateTime Function() now;

  const LocalSyncIssueResolver({
    required this.mappings,
    required this.uploadTasks,
    required this.syncIssues,
    this.now = DateTime.now,
  });

  Future<LocalUploadTask> enqueueConflictForUpload(LocalSyncIssue issue) async {
    if (issue.type != 'download_conflict') {
      throw Exception('问题类型不支持加入上传队列');
    }
    final file = File(issue.localPath);
    if (!await file.exists()) {
      throw Exception('冲突副本不存在');
    }
    final relativePath = await _relativePathForIssue(issue);
    final stat = await file.stat();
    final planner = LocalUploadPlanner(uploadTasks: uploadTasks, now: now);
    final tasks = await planner.enqueueScannedFiles([
      LocalSyncFile(
        syncRootId: issue.syncRootId,
        localPath: issue.localPath,
        relativePath: relativePath,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
      ),
    ]);
    await syncIssues.markSyncIssueResolved(issueId: issue.id);
    return tasks.single;
  }

  Future<String> _relativePathForIssue(LocalSyncIssue issue) async {
    final items = await mappings.loadSyncRootMappings();
    for (final mapping in items) {
      if (mapping.syncRootId != issue.syncRootId) {
        continue;
      }
      final root = mapping.localPath.replaceAll('\\', '/');
      final localPath = issue.localPath.replaceAll('\\', '/');
      final rootPrefix = root.endsWith('/') ? root : '$root/';
      if (!localPath.startsWith(rootPrefix)) {
        break;
      }
      return localPath.substring(rootPrefix.length);
    }
    throw Exception('冲突副本不在本地同步目录内');
  }
}
