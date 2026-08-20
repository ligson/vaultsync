import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import '../../core/storage/app_storage.dart';
import '../media_backup/media_backup_gateway.dart';
import 'sync_models.dart';
import 'upload_api_service.dart';

abstract interface class UploadPayloadPreparer {
  Future<PreparedUploadPayload> prepare(
    LocalUploadTask task, {
    required String objectId,
    required String versionId,
  });
}

class UploadSourceChangedException implements Exception {
  const UploadSourceChangedException();

  @override
  String toString() => '文件仍在写入，等待稳定后再上传';
}

abstract interface class LocalUploadExecutionGateway {
  Future<UploadExecutionResult> executePendingUploads({String? syncRootId});
}

abstract interface class LocalUploadCancellationGateway {
  void pauseSyncRootUploads(String syncRootId);

  void confirmSyncRootDeleted(String syncRootId);

  void resumeSyncRootUploads(String syncRootId);
}

abstract interface class UploadSessionProgressReconciler {
  Future<int> reconcilePendingUploadProgress();
}

abstract interface class LocalPostUploadCleaner {
  Future<Object> cleanupUploadedTasks();

  Future<LocalUploadTask> cleanupUploadedTask(LocalUploadTask task);

  Future<int> cleanupDeletedLocalEmptyDirectories({String? syncRootId});
}

class PreparedUploadPayload {
  final List<int> bytes;
  final File? payloadFile;
  final int? payloadFileSize;
  final String payloadHash;
  final List<File> cleanupFiles;
  final String encryptedName;
  final String metadataJson;
  final String sourceContentHash;

  const PreparedUploadPayload({
    this.bytes = const [],
    this.payloadFile,
    this.payloadFileSize,
    this.payloadHash = '',
    this.cleanupFiles = const [],
    required this.encryptedName,
    required this.metadataJson,
    this.sourceContentHash = '',
  }) : assert(payloadFile == null || payloadFileSize != null);

  int get length => payloadFileSize ?? bytes.length;

  Stream<List<int>> openRead() {
    final file = payloadFile;
    return file == null ? Stream.value(bytes) : file.openRead();
  }

  Future<List<int>> readRange(int start, int end) async {
    if (start < 0 || end < start || end > length) {
      throw RangeError.range(end, start, length, 'end');
    }
    final file = payloadFile;
    if (file == null) {
      return bytes.sublist(start, end);
    }
    final reader = await file.open();
    try {
      await reader.setPosition(start);
      final result = await reader.read(end - start);
      if (result.length != end - start) {
        throw Exception('上传临时文件读取不完整，请重新准备后重试');
      }
      return result;
    } finally {
      await reader.close();
    }
  }

  Future<List<int>> readAll() async {
    final file = payloadFile;
    return file == null ? bytes : file.readAsBytes();
  }

  Future<void> cleanupAfterSuccess() async {
    for (final file in cleanupFiles) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // 临时缓存清理失败不能把已经完成的上传改成失败。
      }
    }
  }
}

class UploadExecutionResult {
  final int uploadedCount;
  final int failedCount;
  final int removedCount;

  const UploadExecutionResult({
    required this.uploadedCount,
    this.failedCount = 0,
    this.removedCount = 0,
  });
}

enum UploadProgressPhase {
  idle,
  preparing,
  connecting,
  uploading,
  completing,
  failed,
  completed,
}

class UploadProgress {
  final UploadProgressPhase phase;
  final int taskIndex;
  final int taskCount;
  final String currentPath;
  final int uploadedBytes;
  final int totalBytes;
  final int uploadedCount;
  final int failedCount;
  final int speedBytesPerSecond;
  final String errorMessage;

  const UploadProgress({
    this.phase = UploadProgressPhase.idle,
    this.taskIndex = 0,
    this.taskCount = 0,
    this.currentPath = '',
    this.uploadedBytes = 0,
    this.totalBytes = 0,
    this.uploadedCount = 0,
    this.failedCount = 0,
    this.speedBytesPerSecond = 0,
    this.errorMessage = '',
  });

  bool get isActive => switch (phase) {
    UploadProgressPhase.preparing ||
    UploadProgressPhase.connecting ||
    UploadProgressPhase.uploading ||
    UploadProgressPhase.completing ||
    UploadProgressPhase.failed => true,
    UploadProgressPhase.idle || UploadProgressPhase.completed => false,
  };
}

class UploadProgressChannel extends ChangeNotifier {
  UploadProgress _value = const UploadProgress();

  UploadProgress get value => _value;

  void report(UploadProgress value) {
    _value = value;
    notifyListeners();
  }
}

typedef UploadTaskIDFactory = String Function(LocalUploadTask task);

class LocalUploadExecutor
    implements
        LocalUploadExecutionGateway,
        LocalUploadCancellationGateway,
        UploadSessionProgressReconciler {
  static const _progressPersistBytes = 32 * 1024 * 1024;
  static const _maxStartupSessionChecks = 32;

  final SessionStore sessionStore;
  final SyncRootMappingStore? syncRootMappings;
  final UploadTaskStore uploadTasks;
  final RemoteVersionIndexStore? remoteVersions;
  final UploadGateway uploads;
  final UploadPayloadPreparer payloadPreparer;
  final LocalPostUploadCleaner? postUploadCleaner;
  final UploadTaskIDFactory objectIdForTask;
  final UploadTaskIDFactory versionIdForTask;
  final int chunkSize;
  final UploadProgressChannel? progress;
  final Duration sourceStabilityWindow;
  final DateTime Function() now;
  final Set<String> _pausedSyncRootIds = <String>{};
  final Set<String> _deletedSyncRootIds = <String>{};

  LocalUploadExecutor({
    required this.sessionStore,
    this.syncRootMappings,
    required this.uploadTasks,
    this.remoteVersions,
    required this.uploads,
    required this.payloadPreparer,
    this.postUploadCleaner,
    this.objectIdForTask = _defaultObjectId,
    this.versionIdForTask = _defaultVersionId,
    this.chunkSize = 1024 * 1024,
    this.progress,
    this.sourceStabilityWindow = Duration.zero,
    this.now = DateTime.now,
  });

  @override
  void pauseSyncRootUploads(String syncRootId) {
    final normalizedId = syncRootId.trim();
    if (normalizedId.isNotEmpty) {
      _pausedSyncRootIds.add(normalizedId);
    }
  }

  @override
  void confirmSyncRootDeleted(String syncRootId) {
    final normalizedId = syncRootId.trim();
    if (normalizedId.isNotEmpty) {
      _pausedSyncRootIds.add(normalizedId);
      _deletedSyncRootIds.add(normalizedId);
    }
  }

  @override
  void resumeSyncRootUploads(String syncRootId) {
    final normalizedId = syncRootId.trim();
    _pausedSyncRootIds.remove(normalizedId);
    _deletedSyncRootIds.remove(normalizedId);
  }

  @override
  Future<int> reconcilePendingUploadProgress() async {
    final token = await sessionStore.loadAuthToken();
    if (token == null || token.isEmpty) {
      return 0;
    }
    final tasks = await uploadTasks.loadUploadTasks();
    final candidates =
        tasks
            .where(
              (task) =>
                  !_isSyncRootUploadPaused(task.syncRootId) &&
                  task.uploadSessionId.isNotEmpty &&
                  (task.status == 'pending' || task.status == 'failed'),
            )
            .toList()
          ..sort(
            (left, right) => right.uploadedBytes.compareTo(left.uploadedBytes),
          );
    final sessionsByTaskId = <String, UploadSession>{};
    for (final task in candidates.take(_maxStartupSessionChecks)) {
      try {
        sessionsByTaskId[task.id] = await uploads.getUploadSession(
          token: token,
          sessionId: task.uploadSessionId,
        );
      } on ApiException catch (error) {
        if (error.statusCode != 404) {
          rethrow;
        }
      }
    }
    if (sessionsByTaskId.isEmpty) {
      return 0;
    }
    var changedCount = 0;
    final updatedTasks = <LocalUploadTask>[];
    for (final task in tasks) {
      if (_isSyncRootDeleted(task.syncRootId)) {
        continue;
      }
      final session = sessionsByTaskId[task.id];
      if (session == null) {
        updatedTasks.add(task);
        continue;
      }
      // 已完成会话仍交给执行器收尾，以保存远端基线并执行用户配置的本地清理策略。
      final nextStatus = task.status;
      if (task.uploadedBytes == session.receivedSize &&
          task.uploadTotalSize == session.totalSize &&
          task.uploadChunkSize == session.chunkSize &&
          task.status == nextStatus) {
        updatedTasks.add(task);
        continue;
      }
      changedCount += 1;
      updatedTasks.add(
        _withStatus(
          task,
          nextStatus,
          uploadedBytes: session.receivedSize,
          uploadTotalSize: session.totalSize,
          uploadChunkSize: session.chunkSize,
        ),
      );
    }
    if (changedCount > 0) {
      if (uploadTasks case final IncrementalUploadTaskStore incrementalStore) {
        for (final task in updatedTasks) {
          if (sessionsByTaskId.containsKey(task.id) &&
              !_isSyncRootUploadPaused(task.syncRootId)) {
            await _saveIncrementalTaskUnlessCancelled(incrementalStore, task);
          }
        }
      } else {
        await _saveBulkTasksWithoutDeletedRoots(updatedTasks);
      }
    }
    return changedCount;
  }

  @override
  Future<UploadExecutionResult> executePendingUploads({
    String? syncRootId,
  }) async {
    final token = await sessionStore.loadAuthToken();
    final deviceId = await sessionStore.loadDeviceId();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('设备状态已失效');
    }

    final tasks = await uploadTasks.loadUploadTasks();
    final mappingsByRootId = await _loadMappingsByRootId();
    final taskCount = tasks.where((task) {
      return _shouldUploadTask(task, syncRootId: syncRootId);
    }).length;
    var uploadedCount = 0;
    var failedCount = 0;
    var removedCount = 0;
    var processedTaskCount = 0;
    var lastErrorMessage = '';
    var lastPath = '';
    var lastSpeedBytesPerSecond = 0;
    final updatedTasks = <LocalUploadTask>[];
    for (var taskIndex = 0; taskIndex < tasks.length; taskIndex += 1) {
      final task = tasks[taskIndex];
      if (_isSyncRootUploadPaused(task.syncRootId)) {
        if (!_isSyncRootDeleted(task.syncRootId)) {
          updatedTasks.add(task);
        } else if (uploadTasks
            case final IncrementalUploadTaskStore incrementalStore) {
          await incrementalStore.removeUploadTask(task.id);
        }
        continue;
      }
      if (!_shouldUploadTask(task, syncRootId: syncRootId)) {
        updatedTasks.add(task);
        continue;
      }
      processedTaskCount += 1;
      lastPath = task.relativePath.isNotEmpty
          ? task.relativePath
          : task.localPath;
      var currentTask = _syncTaskWithCurrentMapping(
        task,
        mappingsByRootId[task.syncRootId],
      );
      PreparedUploadPayload? preparedPayload;
      try {
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        currentTask = await _prepareStableSourceTask(currentTask);
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        if (currentTask.status == 'waiting_stable') {
          updatedTasks.add(currentTask);
          if (uploadTasks
              case final IncrementalUploadTaskStore incrementalStore) {
            await _saveIncrementalTaskUnlessCancelled(
              incrementalStore,
              currentTask,
            );
          }
          continue;
        }
        final objectId = objectIdForTask(currentTask);
        final versionId = versionIdForTask(currentTask);
        final uploadTimer = Stopwatch();
        _reportProgress(
          phase: UploadProgressPhase.preparing,
          taskIndex: processedTaskCount,
          taskCount: taskCount,
          currentPath: lastPath,
          uploadedBytes: currentTask.uploadedBytes,
          totalBytes: currentTask.uploadTotalSize,
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          speedBytesPerSecond: lastSpeedBytesPerSecond,
        );
        final knownSession = await _loadKnownSession(
          token: token,
          task: currentTask,
        );
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        if (knownSession != null) {
          currentTask = _withStatus(
            currentTask,
            currentTask.status,
            uploadedBytes: knownSession.receivedSize,
            uploadTotalSize: knownSession.totalSize,
            uploadChunkSize: knownSession.chunkSize,
          );
          _reportProgress(
            phase: UploadProgressPhase.preparing,
            taskIndex: processedTaskCount,
            taskCount: taskCount,
            currentPath: lastPath,
            uploadedBytes: knownSession.receivedSize,
            totalBytes: knownSession.totalSize,
            uploadedCount: uploadedCount,
            failedCount: failedCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
        }
        final payload = await payloadPreparer.prepare(
          currentTask,
          objectId: objectId,
          versionId: versionId,
        );
        preparedPayload = payload;
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        await _ensureSourceUnchanged(currentTask);
        final payloadHash = await _uploadPayloadFingerprint(payload);
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        _reportProgress(
          phase: UploadProgressPhase.connecting,
          taskIndex: processedTaskCount,
          taskCount: taskCount,
          currentPath: lastPath,
          uploadedBytes:
              knownSession?.receivedSize ?? currentTask.uploadedBytes,
          totalBytes: payload.length,
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          speedBytesPerSecond: lastSpeedBytesPerSecond,
        );
        final session = await _resolveUploadSession(
          token: token,
          deviceId: deviceId,
          task: currentTask,
          objectId: objectId,
          versionId: versionId,
          payload: payload,
          payloadHash: payloadHash,
          knownSession: knownSession,
        );
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        currentTask = _withStatus(
          currentTask,
          'pending',
          lastError: '',
          uploadSessionId: session.id,
          uploadPayloadHash: payloadHash,
          uploadTotalSize: payload.length,
          uploadChunkSize: chunkSize,
          uploadedBytes: session.receivedSize,
        );
        await _saveProgress(updatedTasks, tasks, taskIndex, currentTask);
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        uploadTimer.start();
        final initialUploadedBytes = session.receivedSize;

        if (session.status == 'completed') {
          _throwIfSyncRootUploadPaused(currentTask.syncRootId);
          await _saveRemoteVersionBaseline(
            task: currentTask,
            objectId: objectId,
            versionId: versionId,
            sourceContentHash: payload.sourceContentHash,
          );
          _throwIfSyncRootUploadPaused(currentTask.syncRootId);
          currentTask = _withStatus(
            currentTask,
            'uploaded',
            sourceContentHash: payload.sourceContentHash,
            uploadSessionId: session.id,
            uploadPayloadHash: payloadHash,
            uploadTotalSize: payload.length,
            uploadChunkSize: chunkSize,
            uploadedBytes: payload.length,
          );
          currentTask = await _finishUploadedTask(
            completedTasks: updatedTasks,
            originalTasks: tasks,
            currentIndex: taskIndex,
            uploadedTask: currentTask,
          );
          updatedTasks.add(currentTask);
          uploadedCount += 1;
          _reportProgress(
            phase: UploadProgressPhase.completing,
            taskIndex: processedTaskCount,
            taskCount: taskCount,
            currentPath: lastPath,
            uploadedBytes: payload.length,
            totalBytes: payload.length,
            uploadedCount: uploadedCount,
            failedCount: failedCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
          await payload.cleanupAfterSuccess();
          continue;
        }

        _reportProgress(
          phase: UploadProgressPhase.uploading,
          taskIndex: processedTaskCount,
          taskCount: taskCount,
          currentPath: lastPath,
          uploadedBytes: session.receivedSize,
          totalBytes: payload.length,
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          speedBytesPerSecond: lastSpeedBytesPerSecond,
        );
        var partIndex = session.receivedSize ~/ chunkSize;
        var nextProgressPersistAt =
            session.receivedSize + _progressPersistBytes;
        for (
          var offset = session.receivedSize;
          offset < payload.length;
          offset += chunkSize
        ) {
          _throwIfSyncRootUploadPaused(currentTask.syncRootId);
          final end = (offset + chunkSize).clamp(0, payload.length);
          final bytes = await payload.readRange(offset, end);
          _throwIfSyncRootUploadPaused(currentTask.syncRootId);
          await uploads.uploadPart(
            token: token,
            sessionId: session.id,
            partIndex: partIndex,
            bytes: bytes,
          );
          _throwIfSyncRootUploadPaused(currentTask.syncRootId);
          currentTask = _withStatus(
            currentTask,
            'pending',
            lastError: '',
            uploadSessionId: session.id,
            uploadPayloadHash: payloadHash,
            uploadTotalSize: payload.length,
            uploadChunkSize: chunkSize,
            uploadedBytes: end,
          );
          lastSpeedBytesPerSecond = _speedFor(
            end - initialUploadedBytes,
            uploadTimer.elapsed,
          );
          _reportProgress(
            phase: UploadProgressPhase.uploading,
            taskIndex: processedTaskCount,
            taskCount: taskCount,
            currentPath: lastPath,
            uploadedBytes: end,
            totalBytes: payload.length,
            uploadedCount: uploadedCount,
            failedCount: failedCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
          if (end == payload.length || end >= nextProgressPersistAt) {
            await _saveProgress(updatedTasks, tasks, taskIndex, currentTask);
            nextProgressPersistAt = end + _progressPersistBytes;
          }
          partIndex += 1;
        }
        _reportProgress(
          phase: UploadProgressPhase.completing,
          taskIndex: processedTaskCount,
          taskCount: taskCount,
          currentPath: lastPath,
          uploadedBytes: payload.length,
          totalBytes: payload.length,
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          speedBytesPerSecond: lastSpeedBytesPerSecond,
        );
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        await _ensureSourceUnchanged(currentTask);
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        final completedVersion = await uploads.completeUploadSession(
          token: token,
          sessionId: session.id,
        );
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        await _saveRemoteVersionBaseline(
          task: currentTask,
          objectId: objectId,
          versionId: completedVersion.id,
          sourceContentHash: payload.sourceContentHash,
        );
        _throwIfSyncRootUploadPaused(currentTask.syncRootId);
        currentTask = _withStatus(
          currentTask,
          'uploaded',
          sourceContentHash: payload.sourceContentHash,
          uploadSessionId: session.id,
          uploadPayloadHash: payloadHash,
          uploadTotalSize: payload.length,
          uploadChunkSize: chunkSize,
          uploadedBytes: payload.length,
        );
        currentTask = await _finishUploadedTask(
          completedTasks: updatedTasks,
          originalTasks: tasks,
          currentIndex: taskIndex,
          uploadedTask: currentTask,
        );
        updatedTasks.add(currentTask);
        await payload.cleanupAfterSuccess();
        uploadedCount += 1;
      } on _SyncRootUploadPausedException {
        await preparedPayload?.cleanupAfterSuccess();
        if (_isSyncRootDeleted(currentTask.syncRootId)) {
          if (uploadTasks
              case final IncrementalUploadTaskStore incrementalStore) {
            await incrementalStore.removeUploadTask(currentTask.id);
          }
        } else {
          updatedTasks.add(currentTask);
        }
        continue;
      } on UploadSourceChangedException {
        currentTask = await _markSourceChanged(currentTask);
        updatedTasks.add(currentTask);
        if (uploadTasks
            case final IncrementalUploadTaskStore incrementalStore) {
          await _saveIncrementalTaskUnlessCancelled(
            incrementalStore,
            currentTask,
          );
        }
        continue;
      } catch (error) {
        if (_isMissingLocalUploadSource(currentTask, error)) {
          removedCount += 1;
          if (uploadTasks
              case final IncrementalUploadTaskStore incrementalStore) {
            await incrementalStore.removeUploadTask(currentTask.id);
          }
          debugPrint(
            'VaultSync removed upload task because its local source no longer exists: '
            '${currentTask.localPath}',
          );
          continue;
        }
        failedCount += 1;
        lastErrorMessage = _uploadErrorMessage(error);
        currentTask = _withStatus(
          currentTask,
          'failed',
          attempts: currentTask.attempts + 1,
          lastError: lastErrorMessage,
        );
        updatedTasks.add(currentTask);
        if (uploadTasks
            case final IncrementalUploadTaskStore incrementalStore) {
          await _saveIncrementalTaskUnlessCancelled(
            incrementalStore,
            currentTask,
          );
        }
        _reportProgress(
          phase: UploadProgressPhase.failed,
          taskIndex: processedTaskCount,
          taskCount: taskCount,
          currentPath: lastPath,
          uploadedBytes: currentTask.uploadedBytes,
          totalBytes: currentTask.uploadTotalSize,
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          speedBytesPerSecond: lastSpeedBytesPerSecond,
          errorMessage: lastErrorMessage,
        );
      }
    }
    if (uploadTasks is! IncrementalUploadTaskStore) {
      await _saveBulkTasksWithoutDeletedRoots(updatedTasks);
    }
    try {
      await postUploadCleaner?.cleanupDeletedLocalEmptyDirectories(
        syncRootId: syncRootId,
      );
    } catch (_) {
      // Empty-directory pruning is an optional follow-up after confirmed upload
      // cleanup. A concurrent write or permission change should not turn an
      // otherwise successful upload round into a failed upload round.
    }
    _reportProgress(
      phase: UploadProgressPhase.completed,
      taskIndex: taskCount,
      taskCount: taskCount,
      currentPath: lastPath,
      uploadedCount: uploadedCount,
      failedCount: failedCount,
      speedBytesPerSecond: lastSpeedBytesPerSecond,
      errorMessage: lastErrorMessage,
    );
    return UploadExecutionResult(
      uploadedCount: uploadedCount,
      failedCount: failedCount,
      removedCount: removedCount,
    );
  }

  bool _isMissingLocalUploadSource(LocalUploadTask task, Object error) {
    if (task.sourceType == 'media_asset' &&
        error is MissingMediaAssetException) {
      return true;
    }
    if (error is! FileSystemException) {
      return false;
    }
    final isMissingError =
        error is PathNotFoundException ||
        error.osError?.errorCode == 2 ||
        error.osError?.errorCode == 3;
    if (!isMissingError) {
      return false;
    }
    if (task.sourceType == 'media_asset') {
      return true;
    }
    final errorPath = error.path;
    if (errorPath == null || errorPath.trim().isEmpty) {
      return false;
    }
    return _normalizedLocalPath(errorPath) ==
        _normalizedLocalPath(task.localPath);
  }

  bool _isSyncRootUploadPaused(String syncRootId) {
    return _pausedSyncRootIds.contains(syncRootId);
  }

  bool _isSyncRootDeleted(String syncRootId) {
    return _deletedSyncRootIds.contains(syncRootId);
  }

  void _throwIfSyncRootUploadPaused(String syncRootId) {
    if (_isSyncRootUploadPaused(syncRootId)) {
      throw const _SyncRootUploadPausedException();
    }
  }

  String _normalizedLocalPath(String path) {
    final normalized = File(path).absolute.path.replaceAll('\\', '/');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  bool _shouldUploadTask(LocalUploadTask task, {String? syncRootId}) {
    final hasUploadStatus =
        task.status == 'pending' ||
        task.status == 'failed' ||
        task.status == 'waiting_stable';
    return hasUploadStatus &&
        (syncRootId == null || task.syncRootId == syncRootId);
  }

  Future<LocalUploadTask> _prepareStableSourceTask(LocalUploadTask task) async {
    if (sourceStabilityWindow <= Duration.zero || !_usesFileStability(task)) {
      return task;
    }
    final file = File(task.localPath);
    if (!await file.exists()) {
      return task.status == 'waiting_stable'
          ? _withStatus(task, 'pending')
          : task;
    }
    final stat = await file.stat();
    final currentTime = now().toUtc();
    final sameSnapshot =
        stat.size == task.sizeBytes &&
        stat.modified.toUtc().isAtSameMomentAs(task.modifiedAt.toUtc());
    final firstObservation = sameSnapshot
        ? task.stabilityObservedAt
        : currentTime;
    final stableLongEnough =
        firstObservation != null &&
        currentTime.difference(firstObservation) >= sourceStabilityWindow &&
        currentTime.difference(stat.modified.toUtc()) >= sourceStabilityWindow;
    if (!sameSnapshot || !stableLongEnough) {
      return _withSourceSnapshot(
        task,
        sizeBytes: stat.size,
        modifiedAt: stat.modified.toUtc(),
        status: 'waiting_stable',
        stabilityObservedAt: firstObservation ?? currentTime,
        lastError: '文件仍在写入，等待稳定后再上传',
        resetUploadProgress: !sameSnapshot,
      );
    }
    return task.status == 'waiting_stable'
        ? _withStatus(task, 'pending')
        : task;
  }

  LocalUploadTask _withSourceSnapshot(
    LocalUploadTask task, {
    int? sizeBytes,
    DateTime? modifiedAt,
    required String status,
    required DateTime stabilityObservedAt,
    required String lastError,
    bool resetUploadProgress = false,
  }) {
    return LocalUploadTask(
      id: task.id,
      syncRootId: task.syncRootId,
      localPath: task.localPath,
      relativePath: task.relativePath,
      sizeBytes: sizeBytes ?? task.sizeBytes,
      modifiedAt: modifiedAt ?? task.modifiedAt,
      status: status,
      attempts: task.attempts,
      createdAt: task.createdAt,
      stabilityObservedAt: stabilityObservedAt,
      sourceContentHash: resetUploadProgress ? '' : task.sourceContentHash,
      lastError: lastError,
      uploadSessionId: resetUploadProgress ? '' : task.uploadSessionId,
      uploadPayloadHash: resetUploadProgress ? '' : task.uploadPayloadHash,
      uploadTotalSize: resetUploadProgress ? 0 : task.uploadTotalSize,
      uploadChunkSize: resetUploadProgress ? 0 : task.uploadChunkSize,
      uploadedBytes: resetUploadProgress ? 0 : task.uploadedBytes,
      sourceType: task.sourceType,
      assetId: task.assetId,
      assetMediaType: task.assetMediaType,
      encryptionEnabled: task.encryptionEnabled,
    );
  }

  Future<void> _ensureSourceUnchanged(LocalUploadTask task) async {
    if (sourceStabilityWindow <= Duration.zero || !_usesFileStability(task)) {
      return;
    }
    final stat = await File(task.localPath).stat();
    if (stat.size != task.sizeBytes ||
        !stat.modified.toUtc().isAtSameMomentAs(task.modifiedAt.toUtc())) {
      throw const UploadSourceChangedException();
    }
  }

  bool _usesFileStability(LocalUploadTask task) {
    return task.sourceType == 'file' ||
        task.sourceType == 'wechat_file' ||
        task.sourceType == 'wechat_archive_file';
  }

  Future<LocalUploadTask> _markSourceChanged(LocalUploadTask task) async {
    FileStat? stat;
    try {
      stat = await File(task.localPath).stat();
    } on FileSystemException {
      // The next execution removes a task whose source disappeared entirely.
    }
    return _withSourceSnapshot(
      task,
      sizeBytes: stat?.size,
      modifiedAt: stat?.modified.toUtc(),
      status: 'waiting_stable',
      stabilityObservedAt: now().toUtc(),
      lastError: '文件仍在写入，等待稳定后再上传',
      resetUploadProgress: true,
    );
  }

  void _reportProgress({
    required UploadProgressPhase phase,
    required int taskIndex,
    required int taskCount,
    required String currentPath,
    int uploadedBytes = 0,
    int totalBytes = 0,
    required int uploadedCount,
    required int failedCount,
    int speedBytesPerSecond = 0,
    String errorMessage = '',
  }) {
    progress?.report(
      UploadProgress(
        phase: phase,
        taskIndex: taskIndex,
        taskCount: taskCount,
        currentPath: currentPath,
        uploadedBytes: uploadedBytes,
        totalBytes: totalBytes,
        uploadedCount: uploadedCount,
        failedCount: failedCount,
        speedBytesPerSecond: speedBytesPerSecond,
        errorMessage: errorMessage,
      ),
    );
  }

  int _speedFor(int bytes, Duration elapsed) {
    if (bytes <= 0 || elapsed.inMicroseconds <= 0) {
      return 0;
    }
    return (bytes * Duration.microsecondsPerSecond / elapsed.inMicroseconds)
        .round();
  }

  Future<Map<String, LocalSyncRootMapping>> _loadMappingsByRootId() async {
    final mappingsStore = syncRootMappings;
    if (mappingsStore == null) {
      return const {};
    }
    final mappings = await mappingsStore.loadSyncRootMappings();
    return {for (final mapping in mappings) mapping.syncRootId: mapping};
  }

  Future<void> _saveRemoteVersionBaseline({
    required LocalUploadTask task,
    required String objectId,
    required String versionId,
    required String sourceContentHash,
  }) async {
    final store = remoteVersions;
    if (store == null || sourceContentHash.isEmpty) {
      return;
    }
    await store.saveRemoteVersionIndex(
      LocalRemoteVersionIndex(
        syncRootId: task.syncRootId,
        objectId: objectId,
        versionId: versionId,
        relativePath: task.relativePath,
        localPath: task.localPath,
        contentHash: sourceContentHash,
      ),
    );
  }

  LocalUploadTask _syncTaskWithCurrentMapping(
    LocalUploadTask task,
    LocalSyncRootMapping? mapping,
  ) {
    if (mapping == null ||
        task.encryptionEnabled == mapping.encryptionEnabled) {
      return task;
    }
    return LocalUploadTask(
      id: task.id,
      syncRootId: task.syncRootId,
      localPath: task.localPath,
      relativePath: task.relativePath,
      sizeBytes: task.sizeBytes,
      modifiedAt: task.modifiedAt,
      status: task.status,
      attempts: task.attempts,
      createdAt: task.createdAt,
      stabilityObservedAt: task.stabilityObservedAt,
      sourceContentHash: task.sourceContentHash,
      lastError: task.lastError,
      uploadSessionId: '',
      uploadPayloadHash: '',
      uploadTotalSize: 0,
      uploadChunkSize: 0,
      uploadedBytes: 0,
      sourceType: task.sourceType,
      assetId: task.assetId,
      assetMediaType: task.assetMediaType,
      encryptionEnabled: mapping.encryptionEnabled,
    );
  }

  Future<UploadSession> _resolveUploadSession({
    required String token,
    required String deviceId,
    required LocalUploadTask task,
    required String objectId,
    required String versionId,
    required PreparedUploadPayload payload,
    required String payloadHash,
    UploadSession? knownSession,
  }) async {
    if (_canReuseSession(task, payloadHash, payload.length)) {
      try {
        final session =
            knownSession ??
            await uploads.getUploadSession(
              token: token,
              sessionId: task.uploadSessionId,
            );
        if (session.status == 'pending' &&
            session.totalSize == payload.length &&
            session.chunkSize == chunkSize &&
            session.receivedSize >= 0 &&
            session.receivedSize < payload.length) {
          return session;
        }
        if (session.status == 'completed') {
          return session;
        }
      } on ApiException catch (error) {
        if (error.statusCode != 404) {
          rethrow;
        }
      }
    }
    return uploads.createUploadSession(
      token: token,
      deviceId: deviceId,
      syncRootId: task.syncRootId,
      objectId: objectId,
      versionId: versionId,
      totalSize: payload.length,
      chunkSize: chunkSize,
      encryptedName: payload.encryptedName,
      metadataJson: payload.metadataJson,
    );
  }

  Future<UploadSession?> _loadKnownSession({
    required String token,
    required LocalUploadTask task,
  }) async {
    if (task.uploadSessionId.isEmpty) {
      return null;
    }
    try {
      return await uploads.getUploadSession(
        token: token,
        sessionId: task.uploadSessionId,
      );
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  bool _canReuseSession(
    LocalUploadTask task,
    String payloadHash,
    int payloadSize,
  ) {
    return task.uploadSessionId.isNotEmpty &&
        task.uploadPayloadHash == payloadHash &&
        task.uploadTotalSize == payloadSize &&
        task.uploadChunkSize == chunkSize;
  }

  Future<void> _saveProgress(
    List<LocalUploadTask> completedTasks,
    List<LocalUploadTask> originalTasks,
    int currentIndex,
    LocalUploadTask currentTask,
  ) {
    if (uploadTasks case final IncrementalUploadTaskStore incrementalStore) {
      return _saveIncrementalTaskUnlessCancelled(incrementalStore, currentTask);
    }
    final nextTasks = <LocalUploadTask>[
      ...completedTasks,
      currentTask,
      ...originalTasks.skip(currentIndex + 1),
    ];
    return _saveBulkTasksWithoutDeletedRoots(nextTasks);
  }

  Future<void> _saveIncrementalTaskUnlessCancelled(
    IncrementalUploadTaskStore store,
    LocalUploadTask task,
  ) async {
    if (_isSyncRootUploadPaused(task.syncRootId)) {
      if (_isSyncRootDeleted(task.syncRootId)) {
        await store.removeUploadTask(task.id);
      }
      return;
    }
    await store.saveUploadTask(task);
    if (_isSyncRootDeleted(task.syncRootId)) {
      await store.removeUploadTask(task.id);
    }
  }

  Future<void> _saveBulkTasksWithoutDeletedRoots(
    List<LocalUploadTask> tasks,
  ) async {
    await uploadTasks.saveUploadTasks([
      for (final task in tasks)
        if (!_isSyncRootDeleted(task.syncRootId)) task,
    ]);
    if (_deletedSyncRootIds.isEmpty) {
      return;
    }
    final persistedTasks = await uploadTasks.loadUploadTasks();
    if (persistedTasks.any((task) => _isSyncRootDeleted(task.syncRootId))) {
      await uploadTasks.saveUploadTasks([
        for (final task in persistedTasks)
          if (!_isSyncRootDeleted(task.syncRootId)) task,
      ]);
    }
  }

  Future<LocalUploadTask> _finishUploadedTask({
    required List<LocalUploadTask> completedTasks,
    required List<LocalUploadTask> originalTasks,
    required int currentIndex,
    required LocalUploadTask uploadedTask,
  }) async {
    _throwIfSyncRootUploadPaused(uploadedTask.syncRootId);
    await _saveProgress(
      completedTasks,
      originalTasks,
      currentIndex,
      uploadedTask,
    );
    _throwIfSyncRootUploadPaused(uploadedTask.syncRootId);
    final cleaner = postUploadCleaner;
    if (cleaner == null) {
      return uploadedTask;
    }
    LocalUploadTask cleanedTask;
    try {
      cleanedTask = await cleaner.cleanupUploadedTask(uploadedTask);
    } catch (_) {
      cleanedTask = _withStatus(
        uploadedTask,
        'cleanup_pending',
        lastError: '上传已完成，本地清理暂未执行，请稍后重试',
      );
    }
    _throwIfSyncRootUploadPaused(uploadedTask.syncRootId);
    await _saveProgress(
      completedTasks,
      originalTasks,
      currentIndex,
      cleanedTask,
    );
    return cleanedTask;
  }

  LocalUploadTask _withStatus(
    LocalUploadTask task,
    String status, {
    int? attempts,
    String lastError = '',
    String? uploadSessionId,
    String? uploadPayloadHash,
    int? uploadTotalSize,
    int? uploadChunkSize,
    int? uploadedBytes,
    String? sourceContentHash,
  }) {
    return LocalUploadTask(
      id: task.id,
      syncRootId: task.syncRootId,
      localPath: task.localPath,
      relativePath: task.relativePath,
      sizeBytes: task.sizeBytes,
      modifiedAt: task.modifiedAt,
      status: status,
      attempts: attempts ?? task.attempts,
      createdAt: task.createdAt,
      stabilityObservedAt: task.stabilityObservedAt,
      sourceContentHash: sourceContentHash ?? task.sourceContentHash,
      lastError: lastError,
      uploadSessionId: uploadSessionId ?? task.uploadSessionId,
      uploadPayloadHash: uploadPayloadHash ?? task.uploadPayloadHash,
      uploadTotalSize: uploadTotalSize ?? task.uploadTotalSize,
      uploadChunkSize: uploadChunkSize ?? task.uploadChunkSize,
      uploadedBytes: uploadedBytes ?? task.uploadedBytes,
      sourceType: task.sourceType,
      assetId: task.assetId,
      assetMediaType: task.assetMediaType,
      encryptionEnabled: task.encryptionEnabled,
    );
  }

  String _uploadErrorMessage(Object error) {
    return userReadableErrorMessage(error);
  }

  static String _defaultObjectId(LocalUploadTask task) =>
      objectIdForUploadTask(task);

  static String _defaultVersionId(LocalUploadTask task) =>
      versionIdForUploadTask(task);

  static Future<String> _uploadPayloadFingerprint(
    PreparedUploadPayload payload,
  ) async {
    if (payload.payloadHash.isNotEmpty) {
      return payload.payloadHash;
    }
    final contentHash = (await sha256.bind(payload.openRead()).first)
        .toString();
    return sha256
        .convert(
          utf8.encode(
            '$contentHash\n${payload.encryptedName}\n${payload.metadataJson}',
          ),
        )
        .toString();
  }
}

class _SyncRootUploadPausedException implements Exception {
  const _SyncRootUploadPausedException();
}

String objectIdForUploadTask(LocalUploadTask task) {
  return 'obj-${_stableUploadTaskHash(task)}';
}

String versionIdForUploadTask(LocalUploadTask task) {
  return 'ver-${_stableUploadTaskHash(task)}-${task.modifiedAt.microsecondsSinceEpoch}';
}

String _stableUploadTaskHash(LocalUploadTask task) {
  final digest = sha256.convert(utf8.encode(task.id));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}
