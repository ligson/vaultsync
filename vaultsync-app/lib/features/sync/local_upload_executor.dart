import 'dart:convert';

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

abstract interface class LocalPostUploadCleaner {
  Future<Object> cleanupUploadedTasks();
}

class PreparedUploadPayload {
  final List<int> bytes;
  final String encryptedName;
  final String metadataJson;
  final String sourceContentHash;

  const PreparedUploadPayload({
    required this.bytes,
    required this.encryptedName,
    required this.metadataJson,
    this.sourceContentHash = '',
  });
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

class LocalUploadExecutor implements LocalUploadExecutionGateway {
  static const _progressPersistBytes = 8 * 1024 * 1024;

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
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          speedBytesPerSecond: lastSpeedBytesPerSecond,
        );
        final payload = await payloadPreparer.prepare(
          currentTask,
          objectId: objectId,
          versionId: versionId,
        );
        final payloadHash = _uploadPayloadFingerprint(payload);
        _reportProgress(
          phase: UploadProgressPhase.connecting,
          taskIndex: processedTaskCount,
          taskCount: taskCount,
          currentPath: lastPath,
          totalBytes: payload.bytes.length,
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
        );
        currentTask = _withStatus(
          currentTask,
          'pending',
          lastError: '',
          uploadSessionId: session.id,
          uploadPayloadHash: payloadHash,
          uploadTotalSize: payload.bytes.length,
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
              uploadTotalSize: payload.bytes.length,
              uploadChunkSize: chunkSize,
              uploadedBytes: payload.bytes.length,
            ),
          );
          uploadedCount += 1;
          _reportProgress(
            phase: UploadProgressPhase.completing,
            taskIndex: processedTaskCount,
            taskCount: taskCount,
            currentPath: lastPath,
            uploadedBytes: payload.bytes.length,
            totalBytes: payload.bytes.length,
            uploadedCount: uploadedCount,
            failedCount: failedCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
          continue;
        }

        _reportProgress(
          phase: UploadProgressPhase.uploading,
          taskIndex: processedTaskCount,
          taskCount: taskCount,
          currentPath: lastPath,
          uploadedBytes: session.receivedSize,
          totalBytes: payload.bytes.length,
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          speedBytesPerSecond: lastSpeedBytesPerSecond,
        );
        var partIndex = session.receivedSize ~/ chunkSize;
        var nextProgressPersistAt =
            session.receivedSize + _progressPersistBytes;
        for (
          var offset = session.receivedSize;
          offset < payload.bytes.length;
          offset += chunkSize
        ) {
          final end = (offset + chunkSize).clamp(0, payload.bytes.length);
          await uploads.uploadPart(
            token: token,
            sessionId: session.id,
            partIndex: partIndex,
            bytes: payload.bytes.sublist(offset, end),
          );
          currentTask = _withStatus(
            currentTask,
            'pending',
            lastError: '',
            uploadSessionId: session.id,
            uploadPayloadHash: payloadHash,
            uploadTotalSize: payload.bytes.length,
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
            totalBytes: payload.bytes.length,
            uploadedCount: uploadedCount,
            failedCount: failedCount,
            speedBytesPerSecond: lastSpeedBytesPerSecond,
          );
          if (end == payload.bytes.length || end >= nextProgressPersistAt) {
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
          uploadedBytes: payload.bytes.length,
          totalBytes: payload.bytes.length,
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
            uploadTotalSize: payload.bytes.length,
            uploadChunkSize: chunkSize,
            uploadedBytes: payload.bytes.length,
          ),
        );
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
  }) async {
    if (_canReuseSession(task, payloadHash, payload.bytes.length)) {
      try {
        final session = await uploads.getUploadSession(
          token: token,
          sessionId: task.uploadSessionId,
        );
        if (session.status == 'pending' &&
            session.totalSize == payload.bytes.length &&
            session.chunkSize == chunkSize &&
            session.receivedSize >= 0 &&
            session.receivedSize < payload.bytes.length) {
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
      totalSize: payload.bytes.length,
      chunkSize: chunkSize,
      encryptedName: payload.encryptedName,
      metadataJson: payload.metadataJson,
    );
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

  static String _uploadPayloadFingerprint(PreparedUploadPayload payload) {
    final contentHash = sha256.convert(payload.bytes).toString();
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
