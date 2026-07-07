import '../../core/storage/app_storage.dart';
import 'sync_models.dart';

class LocalUploadPlanner {
  final UploadTaskStore uploadTasks;
  final DateTime Function() now;

  const LocalUploadPlanner({
    required this.uploadTasks,
    this.now = DateTime.now,
  });

  Future<List<LocalUploadTask>> enqueueScannedFiles(
    List<LocalSyncFile> files,
  ) async {
    final existingTasks = await uploadTasks.loadUploadTasks();
    final tasksById = {for (final task in existingTasks) task.id: task};
    final createdAt = now().toUtc();
    final enqueuedTasks = <LocalUploadTask>[];

    for (final file in files) {
      final id = _taskId(file);
      final existingTask = tasksById[id];
      final status = _nextStatus(existingTask, file);
      final task = LocalUploadTask(
        id: id,
        syncRootId: file.syncRootId,
        localPath: file.localPath,
        relativePath: file.relativePath,
        sizeBytes: file.sizeBytes,
        modifiedAt: file.modifiedAt.toUtc(),
        status: status,
        attempts: 0,
        createdAt: existingTask?.createdAt ?? createdAt,
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
      );
      tasksById[id] = task;
      enqueuedTasks.add(task);
    }

    final allTasks = tasksById.values.toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    await uploadTasks.saveUploadTasks(allTasks);
    return enqueuedTasks;
  }

  String _taskId(LocalSyncFile file) {
    return '${file.syncRootId}:${file.relativePath}';
  }

  String _nextStatus(LocalUploadTask? existingTask, LocalSyncFile file) {
    if (existingTask == null) {
      return 'pending';
    }
    if (_isSameFile(existingTask, file) &&
        _isStableUploadedStatus(existingTask.status)) {
      return existingTask.status;
    }
    return 'pending';
  }

  bool _isSameFile(LocalUploadTask? task, LocalSyncFile file) {
    if (task == null) {
      return false;
    }
    return task.sizeBytes == file.sizeBytes &&
        task.modifiedAt.toUtc().isAtSameMomentAs(file.modifiedAt.toUtc());
  }

  bool _isStableUploadedStatus(String status) {
    return status == 'uploaded' || status == 'clean' || status == 'archived';
  }
}
