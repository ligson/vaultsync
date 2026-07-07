import 'dart:io';

import '../../core/storage/app_storage.dart';
import '../media_backup/media_backup_gateway.dart';
import 'local_upload_executor.dart';
import 'sync_models.dart';

export '../media_backup/media_backup_gateway.dart'
    show MediaAssetCleaner, MediaAssetCleanupResult;

class LocalCleanupResult {
  final int cleanedCount;
  final int pendingCount;

  const LocalCleanupResult({
    required this.cleanedCount,
    required this.pendingCount,
  });
}

class LocalCleanupExecutor implements LocalPostUploadCleaner {
  final SyncRootMappingStore mappings;
  final UploadTaskStore uploadTasks;
  final MediaAssetCleaner? mediaCleaner;

  const LocalCleanupExecutor({
    required this.mappings,
    required this.uploadTasks,
    this.mediaCleaner,
  });

  @override
  Future<LocalCleanupResult> cleanupUploadedTasks() async {
    return _cleanupTasks();
  }

  Future<LocalCleanupResult> cleanupTask(String taskId) async {
    return _cleanupTasks(taskId: taskId);
  }

  Future<LocalCleanupResult> confirmMediaCleanupTasks(
    List<String> taskIds,
  ) async {
    if (taskIds.isEmpty) {
      return const LocalCleanupResult(cleanedCount: 0, pendingCount: 0);
    }

    final targetIds = taskIds.toSet();
    final mappingItems = await mappings.loadSyncRootMappings();
    final mappingsByRoot = {
      for (final mapping in mappingItems) mapping.syncRootId: mapping,
    };
    final tasks = await uploadTasks.loadUploadTasks();
    var cleanedCount = 0;
    var pendingCount = 0;

    final updatedTasks = <LocalUploadTask>[];
    for (final task in tasks) {
      if (!targetIds.contains(task.id) ||
          task.sourceType != 'media_asset' ||
          task.status != 'cleanup_pending') {
        updatedTasks.add(task);
        continue;
      }

      final cleanupResult = await _confirmMediaCleanupTask(
        task,
        mappingsByRoot[task.syncRootId],
      );
      if (cleanupResult.cleaned) {
        cleanedCount += 1;
      }
      if (cleanupResult.pending) {
        pendingCount += 1;
      }
      updatedTasks.add(
        _withStatus(
          task,
          cleanupResult.status,
          lastError: cleanupResult.message,
        ),
      );
    }

    await uploadTasks.saveUploadTasks(updatedTasks);
    return LocalCleanupResult(
      cleanedCount: cleanedCount,
      pendingCount: pendingCount,
    );
  }

  Future<void> ignoreCleanupTask(String taskId) async {
    final tasks = await uploadTasks.loadUploadTasks();
    await uploadTasks.saveUploadTasks([
      for (final task in tasks)
        if (task.id == taskId && task.status == 'cleanup_pending')
          _withStatus(task, 'cleanup_ignored', lastError: '已忽略本次本地清理提醒')
        else
          task,
    ]);
  }

  Future<LocalCleanupResult> _cleanupTasks({String? taskId}) async {
    final mappingItems = await mappings.loadSyncRootMappings();
    final mappingsByRoot = {
      for (final mapping in mappingItems) mapping.syncRootId: mapping,
    };
    final tasks = await uploadTasks.loadUploadTasks();
    var cleanedCount = 0;
    var pendingCount = 0;

    final updatedTasks = <LocalUploadTask>[];
    for (final task in tasks) {
      if (taskId != null && task.id != taskId) {
        updatedTasks.add(task);
        continue;
      }
      if (task.status != 'uploaded' && task.status != 'cleanup_pending') {
        updatedTasks.add(task);
        continue;
      }

      final mapping = mappingsByRoot[task.syncRootId];
      final policy = mapping?.cleanupPolicy ?? 'keep';
      final cleanupResult = await _cleanupTask(task, policy, mapping);
      if (cleanupResult.cleaned) {
        cleanedCount += 1;
      }
      if (cleanupResult.pending) {
        pendingCount += 1;
      }
      updatedTasks.add(
        _withStatus(
          task,
          cleanupResult.status,
          lastError: cleanupResult.message,
        ),
      );
    }

    await uploadTasks.saveUploadTasks(updatedTasks);
    return LocalCleanupResult(
      cleanedCount: cleanedCount,
      pendingCount: pendingCount,
    );
  }

  Future<_TaskCleanupResult> _cleanupTask(
    LocalUploadTask task,
    String policy,
    LocalSyncRootMapping? mapping,
  ) async {
    if (policy == 'keep') {
      return const _TaskCleanupResult(status: 'clean', cleaned: true);
    }

    if (task.sourceType == 'media_asset') {
      if (policy == 'delete') {
        return const _TaskCleanupResult(
          status: 'cleanup_pending',
          pending: true,
          message: '相册资源已备份，等待你确认后再删除本地照片和视频',
        );
      }
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '相册清理策略暂不可用，请检查目录设置',
      );
    }

    if (!await _isSameLocalFile(task)) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '本地文件已变化，暂不自动删除，请确认后重试',
      );
    }

    if (policy == 'delete') {
      return _deleteLocalFile(task);
    }
    if (policy == 'archive') {
      return _archiveLocalFile(task, mapping);
    }
    return const _TaskCleanupResult(
      status: 'cleanup_pending',
      pending: true,
      message: '清理策略暂不可用，请检查目录设置',
    );
  }

  Future<_TaskCleanupResult> _confirmMediaCleanupTask(
    LocalUploadTask task,
    LocalSyncRootMapping? mapping,
  ) async {
    if (mapping?.cleanupPolicy != 'delete') {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '清理策略已变更，请重新确认是否删除本机相册资源',
      );
    }

    final cleaner = mediaCleaner;
    if (cleaner == null) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '相册清理能力暂不可用',
      );
    }

    final assetId = task.assetId.trim();
    if (assetId.isEmpty) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '无法定位该照片或视频，暂时不能清理',
      );
    }

    try {
      final result = await cleaner.deleteAsset(assetId);
      if (result.deleted) {
        return const _TaskCleanupResult(status: 'deleted_local', cleaned: true);
      }

      return _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: result.message.isEmpty ? '系统未允许删除本地相册资源' : result.message,
      );
    } catch (_) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '删除本地相册资源失败，请检查相册权限后重试',
      );
    }
  }

  Future<bool> _isSameLocalFile(LocalUploadTask task) async {
    final file = File(task.localPath);
    if (!await file.exists()) {
      return false;
    }
    final stat = await file.stat();
    final modifiedDiff = stat.modified
        .toUtc()
        .difference(task.modifiedAt.toUtc())
        .abs()
        .inSeconds;
    return stat.size == task.sizeBytes && modifiedDiff <= 2;
  }

  Future<_TaskCleanupResult> _deleteLocalFile(LocalUploadTask task) async {
    try {
      await File(task.localPath).delete();
      return const _TaskCleanupResult(status: 'deleted_local', cleaned: true);
    } catch (_) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '删除本地文件失败，请检查文件权限或是否被占用',
      );
    }
  }

  Future<_TaskCleanupResult> _archiveLocalFile(
    LocalUploadTask task,
    LocalSyncRootMapping? mapping,
  ) async {
    final archivePath = mapping?.archivePath.trim() ?? '';
    if (archivePath.isEmpty) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '归档目录未设置，暂时无法清理',
      );
    }
    try {
      final destination = await _availableArchiveFile(
        archivePath,
        task.relativePath,
      );
      await destination.parent.create(recursive: true);
      await File(task.localPath).rename(destination.path);
      return const _TaskCleanupResult(status: 'archived', cleaned: true);
    } catch (_) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '移动到归档目录失败，请检查目录权限',
      );
    }
  }

  Future<File> _availableArchiveFile(
    String archivePath,
    String relativePath,
  ) async {
    final cleanSegments = relativePath.replaceAll('\\', '/').split('/').where((
      segment,
    ) {
      return segment.isNotEmpty && segment != '.' && segment != '..';
    }).toList();
    final relativeSegments = cleanSegments.isEmpty
        ? ['uploaded-file']
        : cleanSegments;
    final parentSegments = relativeSegments.take(relativeSegments.length - 1);
    final fileName = relativeSegments.last;
    final parent = Directory(
      [archivePath, ...parentSegments].join(Platform.pathSeparator),
    );
    final candidate = File('${parent.path}${Platform.pathSeparator}$fileName');
    if (!await candidate.exists()) {
      return candidate;
    }
    final dotIndex = fileName.lastIndexOf('.');
    final stem = dotIndex <= 0 ? fileName : fileName.substring(0, dotIndex);
    final extension = dotIndex <= 0 ? '' : fileName.substring(dotIndex);
    var index = 1;
    while (true) {
      final next = File(
        '${parent.path}${Platform.pathSeparator}$stem-$index$extension',
      );
      if (!await next.exists()) {
        return next;
      }
      index += 1;
    }
  }

  LocalUploadTask _withStatus(
    LocalUploadTask task,
    String status, {
    String lastError = '',
  }) {
    return LocalUploadTask(
      id: task.id,
      syncRootId: task.syncRootId,
      localPath: task.localPath,
      relativePath: task.relativePath,
      sizeBytes: task.sizeBytes,
      modifiedAt: task.modifiedAt,
      status: status,
      attempts: task.attempts,
      createdAt: task.createdAt,
      lastError: lastError,
      uploadSessionId: task.uploadSessionId,
      uploadPayloadHash: task.uploadPayloadHash,
      uploadTotalSize: task.uploadTotalSize,
      uploadChunkSize: task.uploadChunkSize,
      uploadedBytes: task.uploadedBytes,
      sourceType: task.sourceType,
      assetId: task.assetId,
      assetMediaType: task.assetMediaType,
    );
  }
}

class _TaskCleanupResult {
  final String status;
  final bool cleaned;
  final bool pending;
  final String message;

  const _TaskCleanupResult({
    required this.status,
    this.cleaned = false,
    this.pending = false,
    this.message = '',
  });
}
