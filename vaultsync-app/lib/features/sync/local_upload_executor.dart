import 'dart:convert';

import 'package:crypto/crypto.dart';

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

  const PreparedUploadPayload({
    required this.bytes,
    required this.encryptedName,
    required this.metadataJson,
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

typedef UploadTaskIDFactory = String Function(LocalUploadTask task);

class LocalUploadExecutor implements LocalUploadExecutionGateway {
  final SessionStore sessionStore;
  final UploadTaskStore uploadTasks;
  final UploadGateway uploads;
  final UploadPayloadPreparer payloadPreparer;
  final LocalPostUploadCleaner? postUploadCleaner;
  final UploadTaskIDFactory objectIdForTask;
  final UploadTaskIDFactory versionIdForTask;
  final int chunkSize;

  const LocalUploadExecutor({
    required this.sessionStore,
    required this.uploadTasks,
    required this.uploads,
    required this.payloadPreparer,
    this.postUploadCleaner,
    this.objectIdForTask = _defaultObjectId,
    this.versionIdForTask = _defaultVersionId,
    this.chunkSize = 1024 * 1024,
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
    var uploadedCount = 0;
    var failedCount = 0;
    final updatedTasks = <LocalUploadTask>[];
    for (var taskIndex = 0; taskIndex < tasks.length; taskIndex += 1) {
      final task = tasks[taskIndex];
      if (task.status != 'pending' && task.status != 'failed') {
        updatedTasks.add(task);
        continue;
      }
      if (syncRootId != null && task.syncRootId != syncRootId) {
        updatedTasks.add(task);
        continue;
      }
      final objectId = objectIdForTask(task);
      final versionId = versionIdForTask(task);
      var currentTask = task;
      try {
        final payload = await payloadPreparer.prepare(
          task,
          objectId: objectId,
          versionId: versionId,
        );
        final payloadHash = sha256.convert(payload.bytes).toString();
        final session = await _resolveUploadSession(
          token: token,
          deviceId: deviceId,
          task: task,
          objectId: objectId,
          versionId: versionId,
          payload: payload,
          payloadHash: payloadHash,
        );
        currentTask = _withStatus(
          task,
          'pending',
          lastError: '',
          uploadSessionId: session.id,
          uploadPayloadHash: payloadHash,
          uploadTotalSize: payload.bytes.length,
          uploadChunkSize: chunkSize,
          uploadedBytes: session.receivedSize,
        );
        await _saveProgress(updatedTasks, tasks, taskIndex, currentTask);

        if (session.status == 'completed') {
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
          continue;
        }

        var partIndex = session.receivedSize ~/ chunkSize;
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
          await _saveProgress(updatedTasks, tasks, taskIndex, currentTask);
          partIndex += 1;
        }
        await uploads.completeUploadSession(
          token: token,
          sessionId: session.id,
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
        updatedTasks.add(
          _withStatus(
            currentTask,
            'failed',
            attempts: currentTask.attempts + 1,
            lastError: _uploadErrorMessage(error),
          ),
        );
      }
    }
    await uploadTasks.saveUploadTasks(updatedTasks);
    if (postUploadCleaner != null && uploadedCount > 0) {
      await postUploadCleaner!.cleanupUploadedTasks();
    }
    return UploadExecutionResult(
      uploadedCount: uploadedCount,
      failedCount: failedCount,
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
            session.receivedSize <= payload.bytes.length) {
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
    );
  }

  String _uploadErrorMessage(Object error) {
    return userReadableErrorMessage(error);
  }

  static String _defaultObjectId(LocalUploadTask task) {
    return 'obj-${_stableTaskHash(task)}';
  }

  static String _defaultVersionId(LocalUploadTask task) {
    return 'ver-${_stableTaskHash(task)}-${task.modifiedAt.microsecondsSinceEpoch}';
  }

  static String _stableTaskHash(LocalUploadTask task) {
    final digest = sha256.convert(utf8.encode(task.id));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
