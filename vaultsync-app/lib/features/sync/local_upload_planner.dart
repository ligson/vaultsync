import '../../core/storage/app_storage.dart';
import 'sync_models.dart';

class LocalUploadPlanner {
  static const stabilityWindow = Duration(seconds: 60);

  final UploadTaskStore uploadTasks;
  final DateTime Function() now;
  final Duration requiredStability;

  const LocalUploadPlanner({
    required this.uploadTasks,
    this.now = DateTime.now,
    this.requiredStability = stabilityWindow,
  });

  Future<List<LocalUploadTask>> enqueueScannedFiles(
    List<LocalSyncFile> files,
  ) async {
    final existingTasks = await uploadTasks.loadUploadTasks();
    final tasksById = {for (final task in existingTasks) task.id: task};
    final observedAt = now().toUtc();
    final enqueuedTasks = <LocalUploadTask>[];

    for (var index = 0; index < files.length; index += 1) {
      final file = files[index];
      final id = _taskId(file);
      final existingTask = tasksById[id];
      final sameFile = _isSameFile(existingTask, file);
      final firstStableObservation =
          sameFile && _canContinueStabilityObservation(existingTask?.status)
          ? existingTask?.stabilityObservedAt ?? observedAt
          : observedAt;
      final status = _nextStatus(
        existingTask,
        file,
        observedAt: observedAt,
        firstStableObservation: firstStableObservation,
      );
      final task = LocalUploadTask(
        id: id,
        syncRootId: file.syncRootId,
        localPath: file.localPath,
        relativePath: file.relativePath,
        sizeBytes: file.sizeBytes,
        modifiedAt: file.modifiedAt.toUtc(),
        status: status,
        attempts: 0,
        createdAt: existingTask?.createdAt ?? observedAt,
        stabilityObservedAt: firstStableObservation,
        sourceContentHash: sameFile
            ? existingTask?.sourceContentHash ?? ''
            : '',
        lastError: status == existingTask?.status
            ? existingTask?.lastError ?? ''
            : '',
        uploadSessionId: _isSameFile(existingTask, file)
            ? existingTask?.uploadSessionId ?? ''
            : '',
        uploadPayloadHash: _isSameFile(existingTask, file)
            ? existingTask?.uploadPayloadHash ?? ''
            : '',
        uploadTotalSize: _isSameFile(existingTask, file)
            ? existingTask?.uploadTotalSize ?? 0
            : 0,
        uploadChunkSize: _isSameFile(existingTask, file)
            ? existingTask?.uploadChunkSize ?? 0
            : 0,
        uploadedBytes: _isSameFile(existingTask, file)
            ? existingTask?.uploadedBytes ?? 0
            : 0,
        encryptionEnabled: file.encryptionEnabled,
      );
      tasksById[id] = task;
      enqueuedTasks.add(task);
      if ((index + 1) % 200 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    final allTasks = tasksById.values.toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    await uploadTasks.saveUploadTasks(allTasks);
    return enqueuedTasks;
  }

  String _taskId(LocalSyncFile file) {
    return '${file.syncRootId}:${file.relativePath}';
  }

  String _nextStatus(
    LocalUploadTask? existingTask,
    LocalSyncFile file, {
    required DateTime observedAt,
    required DateTime firstStableObservation,
  }) {
    if (existingTask == null) {
      return 'waiting_stable';
    }
    if (_isSameFile(existingTask, file) &&
        _isStableUploadedStatus(existingTask.status)) {
      return existingTask.status;
    }
    if (!_isSameFile(existingTask, file)) {
      return 'waiting_stable';
    }
    final stableLongEnough =
        observedAt.difference(firstStableObservation) >= requiredStability &&
        observedAt.difference(file.modifiedAt.toUtc()) >= requiredStability;
    if (!stableLongEnough) {
      return 'waiting_stable';
    }
    if (existingTask.status == 'failed') {
      return 'failed';
    }
    return 'pending';
  }

  bool _isSameFile(LocalUploadTask? task, LocalSyncFile file) {
    if (task == null) {
      return false;
    }
    return task.sizeBytes == file.sizeBytes &&
        task.modifiedAt.toUtc().isAtSameMomentAs(file.modifiedAt.toUtc()) &&
        task.encryptionEnabled == file.encryptionEnabled;
  }

  bool _isStableUploadedStatus(String status) {
    return status == 'uploaded' || status == 'clean' || status == 'archived';
  }

  bool _canContinueStabilityObservation(String? status) {
    return status == 'waiting_stable' ||
        status == 'pending' ||
        status == 'failed';
  }
}
