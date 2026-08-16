import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../../core/storage/app_storage.dart';
import '../media_backup/media_backup_gateway.dart';
import 'local_upload_executor.dart';
import 'sync_models.dart';

export '../media_backup/media_backup_gateway.dart'
    show
        MediaAssetBatchCleanupResult,
        MediaAssetCleaner,
        MediaAssetCleanupResult;

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

  @override
  Future<int> cleanupDeletedLocalEmptyDirectories({String? syncRootId}) async {
    final mappingItems = await mappings.loadSyncRootMappings();
    final mappingsByRoot = {
      for (final mapping in mappingItems) mapping.syncRootId: mapping,
    };
    final tasks = await uploadTasks.loadUploadTasks();
    return _pruneDeletedLocalTaskEmptyDirectories(
      tasks,
      mappingsByRoot,
      syncRootId: syncRootId,
    );
  }

  Future<LocalCleanupResult> cleanupNewlyUploadedMediaTasks() async {
    return _cleanupTasks(onlyNewMedia: true);
  }

  @override
  Future<LocalUploadTask> cleanupUploadedTask(LocalUploadTask task) async {
    final mappingItems = await mappings.loadSyncRootMappings();
    LocalSyncRootMapping? mapping;
    for (final item in mappingItems) {
      if (item.syncRootId == task.syncRootId) {
        mapping = item;
        break;
      }
    }
    final policy = mapping?.cleanupPolicy ?? 'keep';
    if (task.status != 'uploaded' && task.status != 'clean') {
      return task;
    }
    if (task.sourceType == 'media_asset' && policy == 'delete') {
      if (_hasInvalidFileName(task.relativePath)) {
        return _withStatus(
          task,
          'cleanup_pending',
          lastError: _invalidFileNameCleanupMessage,
        );
      }
      return _withStatus(task, 'uploaded');
    }
    final cleanupResult = await _cleanupTask(task, policy, mapping);
    return _withStatus(
      task,
      cleanupResult.status,
      lastError: cleanupResult.message,
    );
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
    final eligibleTasks = <LocalUploadTask>[];
    for (final task in tasks) {
      if (!targetIds.contains(task.id) ||
          task.sourceType != 'media_asset' ||
          task.status != 'cleanup_pending') {
        continue;
      }
      final mapping = mappingsByRoot[task.syncRootId];
      if (mapping?.cleanupPolicy == 'delete' &&
          !_hasInvalidFileName(task.relativePath) &&
          task.assetId.trim().isNotEmpty) {
        eligibleTasks.add(task);
      }
    }
    final batchResult = await _deleteMediaAssets(eligibleTasks);
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

      final cleanupResult = _confirmedMediaCleanupResult(
        task,
        mappingsByRoot[task.syncRootId],
        batchResult,
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

  Future<LocalCleanupResult> _cleanupTasks({
    String? taskId,
    bool onlyNewMedia = false,
  }) async {
    final mappingItems = await mappings.loadSyncRootMappings();
    final mappingsByRoot = {
      for (final mapping in mappingItems) mapping.syncRootId: mapping,
    };
    final tasks = await uploadTasks.loadUploadTasks();
    final automaticMediaTasks = <LocalUploadTask>[];
    for (final task in tasks) {
      if ((taskId == null || task.id == taskId) &&
          task.sourceType == 'media_asset' &&
          task.status == 'uploaded' &&
          mappingsByRoot[task.syncRootId]?.cleanupPolicy == 'delete' &&
          !_hasInvalidFileName(task.relativePath) &&
          task.assetId.trim().isNotEmpty) {
        automaticMediaTasks.add(task);
      }
    }
    final mediaBatchResult = await _deleteMediaAssets(automaticMediaTasks);
    var cleanedCount = 0;
    var pendingCount = 0;

    final updatedTasks = <LocalUploadTask>[];
    for (final task in tasks) {
      if (onlyNewMedia &&
          (task.sourceType != 'media_asset' || task.status != 'uploaded')) {
        updatedTasks.add(task);
        continue;
      }
      if (taskId != null && task.id != taskId) {
        updatedTasks.add(task);
        continue;
      }
      if (task.status != 'uploaded' &&
          task.status != 'cleanup_pending' &&
          task.status != 'clean') {
        updatedTasks.add(task);
        continue;
      }

      final mapping = mappingsByRoot[task.syncRootId];
      final policy = mapping?.cleanupPolicy ?? 'keep';
      final cleanupResult = task.sourceType == 'media_asset'
          ? _automaticMediaCleanupResult(task, policy, mediaBatchResult)
          : await _cleanupTask(task, policy, mapping);
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
    await _pruneDeletedLocalTaskEmptyDirectories(
      updatedTasks,
      mappingsByRoot,
      taskId: taskId,
    );
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
          message: '相册资源已备份，等待系统允许批量删除本地照片和视频',
        );
      }
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '相册清理策略暂不可用，请检查目录设置',
      );
    }

    if (policy == 'delete' && _hasInvalidFileName(task.relativePath)) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: _invalidFileNameCleanupMessage,
      );
    }

    if (!await File(task.localPath).exists()) {
      if (policy == 'delete') {
        await _pruneEmptyParentDirectories(task, mapping);
        return const _TaskCleanupResult(
          status: 'deleted_local',
          cleaned: true,
          message: '本地文件已不存在，已确认服务器备份状态',
        );
      }
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '本地文件已不存在，无法执行归档清理',
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
      return _deleteLocalFile(task, mapping);
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

  _TaskCleanupResult _automaticMediaCleanupResult(
    LocalUploadTask task,
    String policy,
    _MediaBatchDeleteResult batchResult,
  ) {
    if (policy == 'keep') {
      return const _TaskCleanupResult(status: 'clean', cleaned: true);
    }
    if (policy != 'delete') {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '相册清理策略暂不可用，请检查目录设置',
      );
    }
    if (_hasInvalidFileName(task.relativePath)) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: _invalidFileNameCleanupMessage,
      );
    }
    if (task.status != 'uploaded') {
      return _TaskCleanupResult(
        status: task.status == 'clean' ? 'cleanup_pending' : task.status,
        pending: true,
        message: task.lastError.isEmpty
            ? '历史相册资源已备份，确认一次即可批量清理本地照片和视频'
            : task.lastError,
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
    if (batchResult.deletedAssetIds.contains(assetId)) {
      return const _TaskCleanupResult(status: 'deleted_local', cleaned: true);
    }
    return _TaskCleanupResult(
      status: 'cleanup_pending',
      pending: true,
      message: batchResult.message.isEmpty
          ? '系统未允许删除本地相册资源，回到前台后可批量重试'
          : batchResult.message,
    );
  }

  _TaskCleanupResult _confirmedMediaCleanupResult(
    LocalUploadTask task,
    LocalSyncRootMapping? mapping,
    _MediaBatchDeleteResult batchResult,
  ) {
    if (mapping?.cleanupPolicy != 'delete') {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '清理策略已变更，请重新确认是否删除本机相册资源',
      );
    }
    if (_hasInvalidFileName(task.relativePath)) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: _invalidFileNameCleanupMessage,
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

    if (batchResult.deletedAssetIds.contains(assetId)) {
      return const _TaskCleanupResult(status: 'deleted_local', cleaned: true);
    }
    return _TaskCleanupResult(
      status: 'cleanup_pending',
      pending: true,
      message: batchResult.message.isEmpty
          ? '系统未允许删除本地相册资源'
          : batchResult.message,
    );
  }

  Future<_MediaBatchDeleteResult> _deleteMediaAssets(
    List<LocalUploadTask> tasks,
  ) async {
    if (tasks.isEmpty) {
      return const _MediaBatchDeleteResult();
    }
    final cleaner = mediaCleaner;
    if (cleaner == null) {
      return const _MediaBatchDeleteResult(message: '相册清理能力暂不可用');
    }
    final assetIds = tasks.map((task) => task.assetId.trim()).toSet().toList();
    try {
      final result = await cleaner.deleteAssets(assetIds);
      return _MediaBatchDeleteResult(
        deletedAssetIds: result.deletedAssetIds,
        message: result.message,
      );
    } catch (_) {
      return const _MediaBatchDeleteResult(
        message: '删除本地相册资源失败，请回到前台并检查相册权限后重试',
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
        .abs();
    if (stat.size != task.sizeBytes ||
        modifiedDiff > const Duration(seconds: 2)) {
      return false;
    }
    final expectedHash = task.sourceContentHash.trim();
    if (expectedHash.isEmpty) {
      return true;
    }
    final currentHash = await crypto.sha256.bind(file.openRead()).first;
    return currentHash.toString() == expectedHash;
  }

  Future<_TaskCleanupResult> _deleteLocalFile(
    LocalUploadTask task,
    LocalSyncRootMapping? mapping,
  ) async {
    try {
      await File(task.localPath).delete();
      await _pruneEmptyParentDirectories(task, mapping);
      return const _TaskCleanupResult(status: 'deleted_local', cleaned: true);
    } catch (_) {
      return const _TaskCleanupResult(
        status: 'cleanup_pending',
        pending: true,
        message: '删除本地文件失败，请检查文件权限或是否被占用',
      );
    }
  }

  Future<int> _pruneEmptyParentDirectories(
    LocalUploadTask task,
    LocalSyncRootMapping? mapping,
  ) async {
    return _pruneEmptyParentDirectoryPath(
      File(task.localPath).parent.path,
      mapping,
    );
  }

  Future<int> _pruneEmptyParentDirectoryPath(
    String parentPath,
    LocalSyncRootMapping? mapping,
  ) async {
    final rootPath = mapping?.localPath.trim() ?? '';
    final candidatePath = parentPath.trim();
    if (rootPath.isEmpty || candidatePath.isEmpty) {
      return 0;
    }

    try {
      final rootDirectory = Directory(rootPath);
      if (!await rootDirectory.exists()) {
        return 0;
      }
      final resolvedRoot = Directory(
        await rootDirectory.resolveSymbolicLinks(),
      );
      final rootKey = _pathComparisonKey(resolvedRoot.path);
      if (rootKey == _pathComparisonKey(resolvedRoot.parent.path)) {
        return 0;
      }

      var current = Directory(candidatePath);
      if (!await current.exists()) {
        return 0;
      }
      current = Directory(await current.resolveSymbolicLinks());
      var currentKey = _pathComparisonKey(current.path);
      if (!_isPathWithinRoot(currentKey, rootKey)) {
        return 0;
      }

      var prunedCount = 0;
      while (currentKey != rootKey) {
        if (!await current.list(followLinks: false).isEmpty) {
          return prunedCount;
        }
        final parent = current.parent;
        await current.delete();
        prunedCount += 1;
        current = parent;
        currentKey = _pathComparisonKey(current.path);
        if (!_isPathWithinRoot(currentKey, rootKey)) {
          return prunedCount;
        }
      }
      return prunedCount;
    } catch (_) {
      // The file is already safely removed; a concurrent write or directory
      // permission change should only stop optional empty-directory pruning.
      return 0;
    }
  }

  Future<int> _pruneDeletedLocalTaskEmptyDirectories(
    List<LocalUploadTask> tasks,
    Map<String, LocalSyncRootMapping> mappingsByRoot, {
    String? syncRootId,
    String? taskId,
  }) async {
    final seen = <String>{};
    final candidates = <_EmptyDirectoryPruneCandidate>[];
    for (final task in tasks) {
      if (task.status != 'deleted_local' ||
          task.sourceType == 'media_asset' ||
          (syncRootId != null && task.syncRootId != syncRootId) ||
          (taskId != null && task.id != taskId)) {
        continue;
      }
      final mapping = mappingsByRoot[task.syncRootId];
      if (mapping == null ||
          mapping.cleanupPolicy != 'delete' ||
          task.localPath.trim().isEmpty) {
        continue;
      }
      final sourceFile = File(task.localPath);
      if (await sourceFile.exists()) {
        continue;
      }
      final parentPath = sourceFile.parent.path;
      final key = '${task.syncRootId}\n${_pathComparisonKey(parentPath)}';
      if (!seen.add(key)) {
        continue;
      }
      candidates.add(
        _EmptyDirectoryPruneCandidate(parentPath: parentPath, mapping: mapping),
      );
    }

    candidates.sort(
      (left, right) =>
          _pathDepth(right.parentPath).compareTo(_pathDepth(left.parentPath)),
    );

    var prunedCount = 0;
    for (final candidate in candidates) {
      prunedCount += await _pruneEmptyParentDirectoryPath(
        candidate.parentPath,
        candidate.mapping,
      );
    }
    return prunedCount;
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
      stabilityObservedAt: task.stabilityObservedAt,
      sourceContentHash: task.sourceContentHash,
      lastError: lastError,
      uploadSessionId: task.uploadSessionId,
      uploadPayloadHash: task.uploadPayloadHash,
      uploadTotalSize: task.uploadTotalSize,
      uploadChunkSize: task.uploadChunkSize,
      uploadedBytes: task.uploadedBytes,
      sourceType: task.sourceType,
      assetId: task.assetId,
      assetMediaType: task.assetMediaType,
      encryptionEnabled: task.encryptionEnabled,
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

class _MediaBatchDeleteResult {
  final Set<String> deletedAssetIds;
  final String message;

  const _MediaBatchDeleteResult({
    this.deletedAssetIds = const <String>{},
    this.message = '',
  });
}

class _EmptyDirectoryPruneCandidate {
  final String parentPath;
  final LocalSyncRootMapping mapping;

  const _EmptyDirectoryPruneCandidate({
    required this.parentPath,
    required this.mapping,
  });
}

const _invalidFileNameCleanupMessage = '文件名编码异常，为避免无法恢复原始名称，已保留本地文件，请先重命名后重新扫描';

bool _hasInvalidFileName(String relativePath) =>
    relativePath.contains('\uFFFD');

String _pathComparisonKey(String path) {
  var value = path;
  while (value.length > 1 && value.endsWith(Platform.pathSeparator)) {
    value = value.substring(0, value.length - 1);
  }
  return Platform.isWindows ? value.toLowerCase() : value;
}

bool _isPathWithinRoot(String path, String rootPath) {
  if (path == rootPath) {
    return true;
  }
  final prefix = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  return path.startsWith(prefix);
}

int _pathDepth(String path) =>
    path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).length;
