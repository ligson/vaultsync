import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/storage/app_storage.dart';
import 'sync_models.dart';

class RemoteDeleteResult {
  final bool deleted;
  final bool blockedLocalChange;

  const RemoteDeleteResult({
    required this.deleted,
    required this.blockedLocalChange,
  });
}

abstract interface class RemoteDeleteHandler {
  Future<RemoteDeleteResult> handleRemoteDelete({
    required String syncRootId,
    required String objectId,
  });
}

class LocalRemoteDeleteHandler implements RemoteDeleteHandler {
  final RemoteVersionIndexStore remoteVersions;
  final SyncIssueStore? syncIssues;

  const LocalRemoteDeleteHandler({
    required this.remoteVersions,
    this.syncIssues,
  });

  @override
  Future<RemoteDeleteResult> handleRemoteDelete({
    required String syncRootId,
    required String objectId,
  }) async {
    final index = await _indexFor(syncRootId, objectId);
    if (index == null) {
      return const RemoteDeleteResult(
        deleted: false,
        blockedLocalChange: false,
      );
    }

    final file = File(index.localPath);
    if (!await file.exists()) {
      await remoteVersions.removeRemoteVersionIndex(
        syncRootId: syncRootId,
        objectId: objectId,
      );
      return const RemoteDeleteResult(
        deleted: false,
        blockedLocalChange: false,
      );
    }

    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != index.contentHash) {
      await syncIssues?.saveSyncIssue(
        LocalSyncIssue(
          id: 'remote_delete_blocked:$syncRootId:$objectId',
          type: 'remote_delete_blocked',
          syncRootId: syncRootId,
          objectId: objectId,
          versionId: index.versionId,
          relativePath: index.relativePath,
          localPath: index.localPath,
          message: '远端删除被本地改动保护',
          status: 'open',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      return const RemoteDeleteResult(deleted: false, blockedLocalChange: true);
    }

    await file.delete();
    await remoteVersions.removeRemoteVersionIndex(
      syncRootId: syncRootId,
      objectId: objectId,
    );
    return const RemoteDeleteResult(deleted: true, blockedLocalChange: false);
  }

  Future<LocalRemoteVersionIndex?> _indexFor(
    String syncRootId,
    String objectId,
  ) async {
    final entries = await remoteVersions.loadRemoteVersionIndexes();
    for (final entry in entries) {
      if (entry.syncRootId == syncRootId && entry.objectId == objectId) {
        return entry;
      }
    }
    return null;
  }
}
