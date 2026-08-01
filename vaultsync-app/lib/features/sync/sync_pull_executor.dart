import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/storage/app_storage.dart';
import '../download/download_service.dart';
import 'encrypted_download_payload_decrypter.dart';
import 'local_download_writer.dart';
import 'local_remote_delete_handler.dart';
import 'local_upload_executor.dart';
import 'remote_metadata_decrypter.dart';
import 'sync_models.dart';
import 'sync_service.dart';

class SyncPullResult {
  final int downloadedCount;
  final int deleteCount;
  final int blockedDeleteCount;
  final int skippedDownloadCount;
  final int nextCursor;
  final bool hasMore;

  const SyncPullResult({
    required this.downloadedCount,
    required this.deleteCount,
    this.blockedDeleteCount = 0,
    this.skippedDownloadCount = 0,
    required this.nextCursor,
    required this.hasMore,
  });
}

enum DownloadProgressPhase {
  idle,
  connecting,
  downloading,
  processing,
  completing,
  failed,
  completed,
}

class DownloadProgress {
  final DownloadProgressPhase phase;
  final int taskIndex;
  final int taskCount;
  final String currentPath;
  final int downloadedBytes;
  final int totalBytes;
  final int downloadedCount;
  final int failedCount;
  final int skippedCount;
  final int speedBytesPerSecond;
  final String errorMessage;

  const DownloadProgress({
    this.phase = DownloadProgressPhase.idle,
    this.taskIndex = 0,
    this.taskCount = 0,
    this.currentPath = '',
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.downloadedCount = 0,
    this.failedCount = 0,
    this.skippedCount = 0,
    this.speedBytesPerSecond = 0,
    this.errorMessage = '',
  });

  bool get isActive => switch (phase) {
    DownloadProgressPhase.connecting ||
    DownloadProgressPhase.downloading ||
    DownloadProgressPhase.processing ||
    DownloadProgressPhase.completing ||
    DownloadProgressPhase.failed => true,
    DownloadProgressPhase.idle || DownloadProgressPhase.completed => false,
  };
}

class DownloadProgressChannel extends ChangeNotifier {
  DownloadProgress _value = const DownloadProgress();

  DownloadProgress get value => _value;

  void report(DownloadProgress value) {
    _value = value;
    notifyListeners();
  }
}

abstract interface class RemoteSyncPullGateway {
  Future<SyncPullResult> pullRemoteChanges();
}

class SyncPullExecutor implements RemoteSyncPullGateway {
  final SessionStore sessionStore;
  final SyncCursorStore cursorStore;
  final SyncChangeGateway changes;
  final DownloadGateway downloads;
  final DownloadPayloadDecrypter decrypter;
  final RemoteObjectWriter writer;
  final RemoteDeleteHandler deleteHandler;
  final SyncRootMappingStore? mappings;
  final RemoteVersionIndexStore? remoteVersions;
  final UploadTaskStore? uploadTasks;
  final RemoteMetadataDecrypter? metadataDecrypter;
  final int limit;
  final DownloadProgressChannel? progress;

  const SyncPullExecutor({
    required this.sessionStore,
    required this.cursorStore,
    required this.changes,
    required this.downloads,
    required this.decrypter,
    required this.writer,
    required this.deleteHandler,
    this.mappings,
    this.remoteVersions,
    this.uploadTasks,
    this.metadataDecrypter,
    this.limit = 100,
    this.progress,
  });

  @override
  Future<SyncPullResult> pullRemoteChanges() async {
    final token = await sessionStore.loadAuthToken();
    final deviceId = await sessionStore.loadDeviceId();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('设备状态已失效');
    }

    final cursor = await cursorStore.loadRemoteCursor();
    final page = await changes.listChanges(
      token: token,
      deviceId: deviceId,
      cursor: cursor,
      limit: limit,
    );

    final mappingItems = await mappings?.loadSyncRootMappings() ?? const [];
    final mappingsByRoot = {
      for (final mapping in mappingItems) mapping.syncRootId: mapping,
    };
    final versionItems =
        await remoteVersions?.loadRemoteVersionIndexes() ?? const [];
    final versionsByObject = {
      for (final version in versionItems)
        _remoteVersionKey(version.syncRootId, version.objectId): version,
    };
    final localUploadTasks = await uploadTasks?.loadUploadTasks() ?? const [];
    final uploadedTasksByVersion = <String, LocalUploadTask>{};
    for (final task in localUploadTasks) {
      if (!_isUploadedStatus(task.status)) {
        continue;
      }
      uploadedTasksByVersion[_uploadedVersionKey(
            task.syncRootId,
            objectIdForUploadTask(task),
            versionIdForUploadTask(task),
          )] =
          task;
    }

    final taskCount = page.items
        .where(
          (item) => item.changeType == 'upsert' && item.versionId.isNotEmpty,
        )
        .length;
    var downloadedCount = 0;
    var deleteCount = 0;
    var blockedDeleteCount = 0;
    var skippedDownloadCount = 0;
    var taskIndex = 0;
    var lastPath = '';
    var lastSpeedBytesPerSecond = 0;
    var lastTotalBytes = 0;
    for (final item in page.items) {
      if (item.changeType == 'upsert' && item.versionId.isNotEmpty) {
        taskIndex += 1;
        lastPath = '远端文件 ${_shortProgressId(item.versionId)}';
        try {
          final skipDownload = await _shouldSkipDownload(
            item: item,
            mapping: mappingsByRoot[item.syncRootId],
            versionsByObject: versionsByObject,
            uploadedTasksByVersion: uploadedTasksByVersion,
          );
          if (skipDownload) {
            skippedDownloadCount += 1;
            _reportProgress(
              phase: DownloadProgressPhase.processing,
              taskIndex: taskIndex,
              taskCount: taskCount,
              currentPath: '已确认远端版本一致，无需下载',
              downloadedCount: downloadedCount,
              failedCount: 0,
              skippedCount: skippedDownloadCount,
              speedBytesPerSecond: lastSpeedBytesPerSecond,
            );
            continue;
          }
          _reportProgress(
            phase: DownloadProgressPhase.connecting,
            taskIndex: taskIndex,
            taskCount: taskCount,
            currentPath: lastPath,
            downloadedCount: downloadedCount,
            failedCount: 0,
            skippedCount: skippedDownloadCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
          final downloadTimer = Stopwatch()..start();
          final object = await downloads.downloadCiphertext(
            token: token,
            versionId: item.versionId,
            objectId: item.objectId,
            syncRootId: item.syncRootId,
            encryptedName: item.encryptedName,
          );
          downloadTimer.stop();
          lastTotalBytes = item.sizeBytes > 0
              ? item.sizeBytes
              : object.bytes.length;
          lastSpeedBytesPerSecond = _speedFor(
            object.bytes.length,
            downloadTimer.elapsed,
          );
          _reportProgress(
            phase: DownloadProgressPhase.downloading,
            taskIndex: taskIndex,
            taskCount: taskCount,
            currentPath: lastPath,
            downloadedBytes: object.bytes.length,
            totalBytes: lastTotalBytes,
            downloadedCount: downloadedCount,
            failedCount: 0,
            skippedCount: skippedDownloadCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
          _verifyDownloadedObject(item, object.bytes);
          final decrypted = await decrypter.decrypt(
            syncRootId: item.syncRootId,
            objectId: item.objectId,
            versionId: item.versionId,
            encryptedName: item.encryptedName,
            metadataJson: item.metadataJson,
            payloadBytes: object.bytes,
          );
          lastPath = decrypted.relativePath;
          _reportProgress(
            phase: DownloadProgressPhase.processing,
            taskIndex: taskIndex,
            taskCount: taskCount,
            currentPath: lastPath,
            downloadedBytes: object.bytes.length,
            totalBytes: lastTotalBytes,
            downloadedCount: downloadedCount,
            failedCount: 0,
            skippedCount: skippedDownloadCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
          await writer.writeRemoteObject(
            syncRootId: item.syncRootId,
            objectId: item.objectId,
            versionId: item.versionId,
            object: decrypted,
          );
          downloadedCount += 1;
          _reportProgress(
            phase: DownloadProgressPhase.completing,
            taskIndex: taskIndex,
            taskCount: taskCount,
            currentPath: lastPath,
            downloadedBytes: object.bytes.length,
            totalBytes: lastTotalBytes,
            downloadedCount: downloadedCount,
            failedCount: 0,
            skippedCount: skippedDownloadCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
        } catch (error) {
          _reportProgress(
            phase: DownloadProgressPhase.failed,
            taskIndex: taskIndex,
            taskCount: taskCount,
            currentPath: lastPath,
            downloadedCount: downloadedCount,
            failedCount: 1,
            skippedCount: skippedDownloadCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
            errorMessage: error.toString(),
          );
          rethrow;
        }
      } else if (item.changeType == 'delete') {
        final deleteResult = await deleteHandler.handleRemoteDelete(
          syncRootId: item.syncRootId,
          objectId: item.objectId,
        );
        deleteCount += 1;
        if (deleteResult.blockedLocalChange) {
          blockedDeleteCount += 1;
        }
      }
    }

    await cursorStore.saveRemoteCursor(page.nextCursor);
    _reportProgress(
      phase: DownloadProgressPhase.completed,
      taskIndex: taskCount,
      taskCount: taskCount,
      currentPath: lastPath,
      downloadedBytes: lastTotalBytes,
      totalBytes: lastTotalBytes,
      downloadedCount: downloadedCount,
      failedCount: 0,
      skippedCount: skippedDownloadCount,
      speedBytesPerSecond: lastSpeedBytesPerSecond,
    );
    return SyncPullResult(
      downloadedCount: downloadedCount,
      deleteCount: deleteCount,
      blockedDeleteCount: blockedDeleteCount,
      skippedDownloadCount: skippedDownloadCount,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
    );
  }

  void _reportProgress({
    required DownloadProgressPhase phase,
    required int taskIndex,
    required int taskCount,
    required String currentPath,
    int downloadedBytes = 0,
    int totalBytes = 0,
    required int downloadedCount,
    required int failedCount,
    int skippedCount = 0,
    int speedBytesPerSecond = 0,
    String errorMessage = '',
  }) {
    progress?.report(
      DownloadProgress(
        phase: phase,
        taskIndex: taskIndex,
        taskCount: taskCount,
        currentPath: currentPath,
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes,
        downloadedCount: downloadedCount,
        failedCount: failedCount,
        skippedCount: skippedCount,
        speedBytesPerSecond: speedBytesPerSecond,
        errorMessage: errorMessage,
      ),
    );
  }

  Future<bool> _shouldSkipDownload({
    required SyncChangeItem item,
    required LocalSyncRootMapping? mapping,
    required Map<String, LocalRemoteVersionIndex> versionsByObject,
    required Map<String, LocalUploadTask> uploadedTasksByVersion,
  }) async {
    final key = _remoteVersionKey(item.syncRootId, item.objectId);
    final currentVersion = versionsByObject[key];
    if (currentVersion?.versionId == item.versionId) {
      return true;
    }
    if (mapping?.cleanupPolicy == 'delete') {
      return true;
    }

    final uploadedTask =
        uploadedTasksByVersion[_uploadedVersionKey(
          item.syncRootId,
          item.objectId,
          item.versionId,
        )];
    if (uploadedTask != null) {
      await _saveTaskBaseline(
        item: item,
        task: uploadedTask,
        versionsByObject: versionsByObject,
      );
      return true;
    }

    final metadataReader = metadataDecrypter;
    if (mapping == null || metadataReader == null) {
      return false;
    }
    final entry = await metadataReader.decrypt(_remoteObjectFor(item));
    if (!entry.decryptable || entry.clientContentHash.isEmpty) {
      return false;
    }
    final localFile = _safeLocalFile(mapping.localPath, entry.relativePath);
    if (localFile == null || !await localFile.exists()) {
      return false;
    }
    final localHash = await _hashFile(localFile);
    if (localHash != entry.clientContentHash) {
      return false;
    }
    await _saveBaseline(
      item: item,
      relativePath: entry.relativePath,
      localPath: localFile.path,
      contentHash: localHash,
      versionsByObject: versionsByObject,
    );
    return true;
  }

  bool _isUploadedStatus(String status) {
    return const {
      'uploaded',
      'clean',
      'archived',
      'deleted_local',
      'cleanup_pending',
      'cleanup_ignored',
    }.contains(status);
  }

  Future<void> _saveTaskBaseline({
    required SyncChangeItem item,
    required LocalUploadTask task,
    required Map<String, LocalRemoteVersionIndex> versionsByObject,
  }) async {
    final file = File(task.localPath);
    final contentHash = await file.exists() ? await _hashFile(file) : '';
    if (contentHash.isEmpty) {
      return;
    }
    await _saveBaseline(
      item: item,
      relativePath: task.relativePath,
      localPath: task.localPath,
      contentHash: contentHash,
      versionsByObject: versionsByObject,
    );
  }

  Future<void> _saveBaseline({
    required SyncChangeItem item,
    required String relativePath,
    required String localPath,
    required String contentHash,
    required Map<String, LocalRemoteVersionIndex> versionsByObject,
  }) async {
    final store = remoteVersions;
    if (store == null) {
      return;
    }
    final baseline = LocalRemoteVersionIndex(
      syncRootId: item.syncRootId,
      objectId: item.objectId,
      versionId: item.versionId,
      relativePath: relativePath,
      localPath: localPath,
      contentHash: contentHash,
    );
    await store.saveRemoteVersionIndex(baseline);
    versionsByObject[_remoteVersionKey(item.syncRootId, item.objectId)] =
        baseline;
  }

  RemoteBackupObject _remoteObjectFor(SyncChangeItem item) {
    return RemoteBackupObject(
      cursorValue: item.cursorValue,
      syncRootId: item.syncRootId,
      objectId: item.objectId,
      versionId: item.versionId,
      encryptedName: item.encryptedName,
      contentHash: item.contentHash,
      sizeBytes: item.sizeBytes,
      metadataJson: item.metadataJson,
      updatedAt: item.createdAt,
    );
  }

  File? _safeLocalFile(String rootPath, String relativePath) {
    final normalized = relativePath.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (rootPath.trim().isEmpty ||
        normalized.isEmpty ||
        normalized.startsWith('/') ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      return null;
    }
    return File([rootPath, ...segments].join(Platform.pathSeparator));
  }

  Future<String> _hashFile(File file) async {
    return (await sha256.bind(file.openRead()).first).toString();
  }

  String _remoteVersionKey(String syncRootId, String objectId) {
    return '$syncRootId\u0000$objectId';
  }

  String _uploadedVersionKey(
    String syncRootId,
    String objectId,
    String versionId,
  ) {
    return '$syncRootId\u0000$objectId\u0000$versionId';
  }

  int _speedFor(int bytes, Duration elapsed) {
    if (bytes <= 0 || elapsed.inMicroseconds <= 0) {
      return 0;
    }
    return (bytes * Duration.microsecondsPerSecond / elapsed.inMicroseconds)
        .round();
  }

  String _shortProgressId(String value) {
    final trimmed = value.trim();
    return trimmed.length <= 8 ? trimmed : trimmed.substring(0, 8);
  }

  void _verifyDownloadedObject(SyncChangeItem item, List<int> bytes) {
    if (item.sizeBytes > 0 && bytes.length != item.sizeBytes) {
      throw Exception('密文大小校验失败');
    }
    if (item.contentHash.isNotEmpty) {
      final actualHash = sha256.convert(bytes).toString();
      if (actualHash != item.contentHash) {
        throw Exception('密文哈希校验失败');
      }
    }
  }
}
