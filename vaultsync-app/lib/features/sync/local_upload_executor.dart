import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import '../../core/storage/app_storage.dart';
import 'sync_models.dart';
import 'upload_api_service.dart';

abstract interface class UploadPayloadPreparer {
  Future<PreparedUploadPayload> prepare(
    LocalUploadTask task, {
    required String objectId,
    required String versionId,
  });
}

abstract interface class LocalUploadExecutionGateway {
  Future<UploadExecutionResult> executePendingUploads({String? syncRootId});
}

abstract interface class UploadSessionProgressReconciler {
  Future<int> reconcilePendingUploadProgress();
}

abstract interface class LocalPostUploadCleaner {
  Future<Object> cleanupUploadedTasks();
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

  const UploadExecutionResult({
    required this.uploadedCount,
    this.failedCount = 0,
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
    implements LocalUploadExecutionGateway, UploadSessionProgressReconciler {
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

  const LocalUploadExecutor({
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
  });

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
      await uploadTasks.saveUploadTasks(updatedTasks);
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
    var processedTaskCount = 0;
    var lastErrorMessage = '';
    var lastPath = '';
    var lastSpeedBytesPerSecond = 0;
    final updatedTasks = <LocalUploadTask>[];
    for (var taskIndex = 0; taskIndex < tasks.length; taskIndex += 1) {
      final task = tasks[taskIndex];
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
      final objectId = objectIdForTask(currentTask);
      final versionId = versionIdForTask(currentTask);
      try {
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
        final payloadHash = await _uploadPayloadFingerprint(payload);
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
        uploadTimer.start();
        final initialUploadedBytes = session.receivedSize;

        if (session.status == 'completed') {
          await _saveRemoteVersionBaseline(
            task: currentTask,
            objectId: objectId,
            versionId: versionId,
            sourceContentHash: payload.sourceContentHash,
          );
          updatedTasks.add(
            _withStatus(
              currentTask,
              'uploaded',
              uploadSessionId: session.id,
              uploadPayloadHash: payloadHash,
              uploadTotalSize: payload.length,
              uploadChunkSize: chunkSize,
              uploadedBytes: payload.length,
            ),
          );
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
          final end = (offset + chunkSize).clamp(0, payload.length);
          await uploads.uploadPart(
            token: token,
            sessionId: session.id,
            partIndex: partIndex,
            bytes: await payload.readRange(offset, end),
          );
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
        final completedVersion = await uploads.completeUploadSession(
          token: token,
          sessionId: session.id,
        );
        await _saveRemoteVersionBaseline(
          task: currentTask,
          objectId: objectId,
          versionId: completedVersion.id,
          sourceContentHash: payload.sourceContentHash,
        );
        updatedTasks.add(
          _withStatus(
            currentTask,
            'uploaded',
            uploadSessionId: session.id,
            uploadPayloadHash: payloadHash,
            uploadTotalSize: payload.length,
            uploadChunkSize: chunkSize,
            uploadedBytes: payload.length,
          ),
        );
        await payload.cleanupAfterSuccess();
        uploadedCount += 1;
      } catch (error) {
        failedCount += 1;
        lastErrorMessage = _uploadErrorMessage(error);
        updatedTasks.add(
          _withStatus(
            currentTask,
            'failed',
            attempts: currentTask.attempts + 1,
            lastError: lastErrorMessage,
          ),
        );
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
    await uploadTasks.saveUploadTasks(updatedTasks);
    if (postUploadCleaner != null && uploadedCount > 0) {
      await postUploadCleaner!.cleanupUploadedTasks();
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
    );
  }

  bool _shouldUploadTask(LocalUploadTask task, {String? syncRootId}) {
    final hasUploadStatus = task.status == 'pending' || task.status == 'failed';
    return hasUploadStatus &&
        (syncRootId == null || task.syncRootId == syncRootId);
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
    final nextTasks = <LocalUploadTask>[
      ...completedTasks,
      currentTask,
      ...originalTasks.skip(currentIndex + 1),
    ];
    return uploadTasks.saveUploadTasks(nextTasks);
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
