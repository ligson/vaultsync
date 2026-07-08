import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/device/device_profile.dart';
import '../../core/network/api_exception.dart';
import '../../core/storage/app_storage.dart';
import '../media_backup/media_backup_models.dart';
import '../media_backup/media_backup_screen.dart';
import '../media_backup/media_backup_gateway.dart';
import '../media_backup/media_backup_scanner.dart';
import 'file_access_permission.dart';
import 'folder_picker.dart';
import 'local_cleanup_executor.dart';
import 'local_path_protector.dart';
import 'local_sync_issue_resolver.dart';
import 'local_sync_scanner.dart';
import 'local_upload_executor.dart';
import 'local_upload_planner.dart';
import 'remote_metadata_decrypter.dart';
import 'sync_models.dart';
import 'sync_pull_executor.dart';
import 'sync_service.dart';

class SyncHomeScreen extends StatefulWidget {
  final SessionStore storage;
  final SyncRootMappingStore syncRootMappings;
  final UploadTaskStore uploadTasks;
  final SyncIssueStore? syncIssues;
  final AutoSyncStatusStore? autoSyncStatus;
  final SyncHistoryStore? syncHistory;
  final SyncRootGateway syncRoots;
  final FolderPicker folderPicker;
  final FileAccessPermissionGateway fileAccessPermission;
  final LocalPathProtector pathProtector;
  final LocalSyncScanGateway? localScanner;
  final LocalUploadExecutionGateway? uploadExecutor;
  final RemoteSyncPullGateway? remotePullExecutor;
  final RemoteBackupGateway? remoteBackups;
  final RemoteObjectDeleteGateway? remoteObjectDeletes;
  final RemoteMetadataDecrypter? remoteMetadataDecrypter;
  final bool autoSyncEnabled;
  final Duration autoSyncInterval;
  final Duration autoSyncInitialDelay;
  final MediaBackupSourceStore? mediaBackupSources;
  final MediaBackupGateway? mediaGateway;
  final String? devicePlatform;
  final Future<void> Function()? onSignOut;

  const SyncHomeScreen({
    super.key,
    required this.storage,
    required this.syncRootMappings,
    required this.uploadTasks,
    this.syncIssues,
    this.autoSyncStatus,
    this.syncHistory,
    required this.syncRoots,
    this.folderPicker = const FileSelectorFolderPicker(),
    this.fileAccessPermission = const PermissionHandlerFileAccessGateway(),
    this.pathProtector = const Sha256LocalPathProtector(),
    this.localScanner,
    this.uploadExecutor,
    this.remotePullExecutor,
    this.remoteBackups,
    this.remoteObjectDeletes,
    this.remoteMetadataDecrypter,
    this.autoSyncEnabled = false,
    this.autoSyncInterval = const Duration(minutes: 5),
    this.autoSyncInitialDelay = const Duration(seconds: 2),
    this.mediaBackupSources,
    this.mediaGateway,
    this.devicePlatform,
    this.onSignOut,
  });

  @override
  State<SyncHomeScreen> createState() => _SyncHomeScreenState();
}

class _SyncHomeScreenState extends State<SyncHomeScreen> {
  late Future<_SyncHomeData> _homeFuture;
  Timer? _initialAutoSyncTimer;
  Timer? _autoSyncTimer;
  var _isScanning = false;
  var _isUploading = false;
  var _isPulling = false;
  var _isAutoSyncing = false;

  @override
  void initState() {
    super.initState();
    _homeFuture = _loadHomeData();
    _startAutoSync();
  }

  @override
  void dispose() {
    _initialAutoSyncTimer?.cancel();
    _autoSyncTimer?.cancel();
    super.dispose();
  }

  void _startAutoSync() {
    if (!widget.autoSyncEnabled) {
      return;
    }
    _initialAutoSyncTimer = Timer(
      widget.autoSyncInitialDelay,
      () => _runAutoSync(scanAndUpload: false),
    );
    _autoSyncTimer = Timer.periodic(
      widget.autoSyncInterval,
      (_) => _runAutoSync(scanAndUpload: true),
    );
  }

  Future<_SyncHomeData> _loadHomeData() async {
    final token = await widget.storage.loadAuthToken();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    final roots = await widget.syncRoots.listSyncRoots(token: token);
    final remoteBackupEntries = await _loadRemoteBackupEntries(token, roots);
    final mappings = await widget.syncRootMappings.loadSyncRootMappings();
    final uploadTasks = await widget.uploadTasks.loadUploadTasks();
    final autoSyncStatus =
        await widget.autoSyncStatus?.loadAutoSyncStatus() ??
        const AutoSyncStatus();
    final prunedState = await _pruneLocalStateForCurrentRoots(
      roots: roots,
      mappings: mappings,
      uploadTasks: uploadTasks,
    );
    final issues = await widget.syncIssues?.loadSyncIssues() ?? const [];
    return _SyncHomeData(
      roots: roots,
      mappings: prunedState.mappings,
      uploadTasks: prunedState.uploadTasks,
      issues: issues,
      remoteBackupEntries: remoteBackupEntries,
      autoSyncStatus: autoSyncStatus,
    );
  }

  Future<_PrunedLocalSyncState> _pruneLocalStateForCurrentRoots({
    required List<SyncRoot> roots,
    required List<LocalSyncRootMapping> mappings,
    required List<LocalUploadTask> uploadTasks,
  }) async {
    final rootIds = {for (final root in roots) root.id};
    final prunedMappings = [
      for (final mapping in mappings)
        if (rootIds.contains(mapping.syncRootId)) mapping,
    ];
    final prunedTasks = [
      for (final task in uploadTasks)
        if (rootIds.contains(task.syncRootId)) task,
    ];
    if (prunedMappings.length != mappings.length) {
      await widget.syncRootMappings.saveSyncRootMappings(prunedMappings);
    }
    if (prunedTasks.length != uploadTasks.length) {
      await widget.uploadTasks.saveUploadTasks(prunedTasks);
    }
    return _PrunedLocalSyncState(
      mappings: prunedMappings,
      uploadTasks: prunedTasks,
    );
  }

  Future<Map<String, List<RemoteBackupEntry>>> _loadRemoteBackupEntries(
    String token,
    List<SyncRoot> roots,
  ) async {
    final gateway = widget.remoteBackups;
    final decrypter = widget.remoteMetadataDecrypter;
    if (gateway == null || decrypter == null) {
      return const {};
    }
    final entriesByRoot = <String, List<RemoteBackupEntry>>{};
    for (final root in roots) {
      final page = await gateway.listRemoteBackupObjects(
        token: token,
        syncRootId: root.id,
        limit: 500,
      );
      final entries = <RemoteBackupEntry>[];
      for (final object in page.items) {
        entries.add(await decrypter.decrypt(object));
      }
      entriesByRoot[root.id] = entries;
    }
    return entriesByRoot;
  }

  Future<void> _addHistory({
    required String type,
    required String result,
    required String title,
    required String message,
    String syncRootId = '',
    String relativePath = '',
  }) async {
    final history = widget.syncHistory;
    if (history == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    await history.addSyncHistory(
      LocalSyncHistoryEntry(
        id: '${now.microsecondsSinceEpoch}-$type',
        type: type,
        result: result,
        title: title,
        message: message,
        syncRootId: syncRootId,
        relativePath: relativePath,
        createdAt: now,
      ),
    );
  }

  void _reloadSyncRoots() {
    setState(() {
      _homeFuture = _loadHomeData();
    });
  }

  Future<void> _signOut() async {
    await widget.onSignOut?.call();
    if (!mounted) {
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _openCreateSyncRootDialog() async {
    final draft = await showDialog<_SyncRootDraft>(
      context: context,
      builder: (context) => _CreateSyncRootDialog(
        folderPicker: widget.folderPicker,
        fileAccessPermission: widget.fileAccessPermission,
        pathProtector: widget.pathProtector,
        showAndroidFileAccessGuide:
            (widget.devicePlatform ?? DeviceProfile.current().platform) ==
            'android',
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    try {
      final token = await widget.storage.loadAuthToken();
      final deviceId = await widget.storage.loadDeviceId();
      if (token == null || token.isEmpty) {
        throw Exception('登录状态已失效');
      }
      if (deviceId == null || deviceId.isEmpty) {
        throw Exception('设备状态已失效');
      }
      final root = await widget.syncRoots.createSyncRoot(
        token: token,
        deviceId: deviceId,
        encryptedPath: draft.encryptedPath,
        cleanupPolicy: draft.cleanupPolicy,
        archivePath: draft.archivePath,
      );
      await widget.syncRootMappings.saveSyncRootMapping(
        LocalSyncRootMapping(
          syncRootId: root.id,
          localPath: draft.localPath,
          encryptedPath: root.encryptedPath,
          cleanupPolicy: root.cleanupPolicy,
          archivePath: root.archivePath,
        ),
      );
      await _addHistory(
        type: 'sync_root',
        result: 'success',
        title: '新增同步目录',
        message: '已添加同步目录 ${draft.localPath}',
        syncRootId: root.id,
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userReadableErrorMessage(error))));
    }
  }

  Future<void> _scanLocalFiles({String? syncRootId}) async {
    if (_isScanning) {
      return;
    }
    setState(() {
      _isScanning = true;
    });
    try {
      await _ensureAndroidSharedMediaDirectoryPermission(syncRootId);
      final scanner =
          widget.localScanner ??
          LocalSyncScanner(mappings: widget.syncRootMappings);
      final files = await scanner.scanMappedRoots(syncRootId: syncRootId);
      final planner = LocalUploadPlanner(uploadTasks: widget.uploadTasks);
      final tasks = await planner.enqueueScannedFiles(files);
      final mediaResult = await _scanMediaBackupSources(
        syncRootId: syncRootId,
        includeDisabled: true,
      );
      final scannedCount = files.length + mediaResult.scannedCount;
      final createdTaskCount = tasks.length + mediaResult.createdTaskCount;
      await _addHistory(
        type: 'scan',
        result: 'success',
        title: syncRootId == null ? '扫描全部同步目录' : '扫描单个同步目录',
        message: '发现 $scannedCount 个本地文件，生成 $createdTaskCount 个待上传任务',
        syncRootId: syncRootId ?? '',
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      final scope = syncRootId == null ? '' : '此目录';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '扫描$scope发现 $scannedCount 个本地文件，生成 $createdTaskCount 个待上传任务',
          ),
        ),
      );
    } catch (error) {
      await _addHistory(
        type: 'scan',
        result: 'failed',
        title: syncRootId == null ? '扫描全部同步目录失败' : '扫描单个同步目录失败',
        message: userReadableErrorMessage(error),
        syncRootId: syncRootId ?? '',
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userReadableErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<void> _executePendingUploads({String? syncRootId}) async {
    final executor = widget.uploadExecutor;
    if (executor == null || _isUploading) {
      return;
    }
    setState(() {
      _isUploading = true;
    });
    try {
      final result = await executor.executePendingUploads(
        syncRootId: syncRootId,
      );
      await _addHistory(
        type: 'upload',
        result: result.failedCount > 0 ? 'failed' : 'success',
        title: syncRootId == null ? '上传待处理任务' : '上传单个同步目录',
        message: '已上传 ${result.uploadedCount} 个任务，失败 ${result.failedCount} 个',
        syncRootId: syncRootId ?? '',
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      final scope = syncRootId == null ? '' : '此目录';
      final failedSuffix = result.failedCount > 0
          ? '，${result.failedCount} 个失败'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已上传$scope ${result.uploadedCount} 个任务$failedSuffix'),
        ),
      );
    } catch (error) {
      await _addHistory(
        type: 'upload',
        result: 'failed',
        title: syncRootId == null ? '上传待处理任务失败' : '上传单个同步目录失败',
        message: userReadableErrorMessage(error),
        syncRootId: syncRootId ?? '',
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userReadableErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  Future<void> _ensureAndroidSharedMediaDirectoryPermission(
    String? syncRootId,
  ) async {
    final platform = widget.devicePlatform ?? DeviceProfile.current().platform;
    if (platform != 'android') {
      return;
    }
    final mediaGateway = widget.mediaGateway;
    if (mediaGateway == null) {
      return;
    }
    final mappings = await widget.syncRootMappings.loadSyncRootMappings();
    final needsMediaPermission = mappings.any((mapping) {
      if (syncRootId != null && mapping.syncRootId != syncRootId) {
        return false;
      }
      if (_isMediaBackupEncryptedPath(mapping.encryptedPath)) {
        return false;
      }
      return _isAndroidSharedMediaDirectory(mapping.localPath);
    });
    if (!needsMediaPermission) {
      return;
    }
    final permission = await mediaGateway.requestPermission();
    if (permission.state == 'granted' || permission.state == 'limited') {
      return;
    }
    throw Exception(
      permission.message.isEmpty ? '未获得相册访问权限' : permission.message,
    );
  }

  bool _isAndroidSharedMediaDirectory(String localPath) {
    final normalized = localPath.trim().replaceAll('\\', '/').toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    return parts.any(
      (part) => part == 'dcim' || part == 'pictures' || part == 'movies',
    );
  }

  Future<void> _retryFailedUploads({String? syncRootId}) async {
    final tasks = await widget.uploadTasks.loadUploadTasks();
    var retryCount = 0;
    final nextTasks = <LocalUploadTask>[];
    for (final task in tasks) {
      if (task.status == 'failed' &&
          (syncRootId == null || task.syncRootId == syncRootId)) {
        retryCount += 1;
        nextTasks.add(_copyUploadTask(task, status: 'pending', lastError: ''));
      } else {
        nextTasks.add(task);
      }
    }
    if (retryCount == 0) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有需要重试的失败任务')));
      return;
    }
    await widget.uploadTasks.saveUploadTasks(nextTasks);
    await _addHistory(
      type: 'retry',
      result: 'info',
      title: syncRootId == null ? '重试上传失败任务' : '重试此目录失败任务',
      message: '已将 $retryCount 个失败任务重新加入上传队列',
      syncRootId: syncRootId ?? '',
    );
    if (!mounted) {
      return;
    }
    _reloadSyncRoots();
    await _executePendingUploads(syncRootId: syncRootId);
  }

  Future<void> _retryCleanupPending() async {
    try {
      final cleaner = LocalCleanupExecutor(
        mappings: widget.syncRootMappings,
        uploadTasks: widget.uploadTasks,
        mediaCleaner: widget.mediaGateway,
      );
      final result = await cleaner.cleanupUploadedTasks();
      await _addHistory(
        type: 'cleanup',
        result: result.pendingCount > 0 ? 'failed' : 'success',
        title: '重试本地清理',
        message:
            '完成 ${result.cleanedCount} 个清理任务，仍待处理 ${result.pendingCount} 个',
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已重试清理，完成 ${result.cleanedCount} 个，仍待处理 ${result.pendingCount} 个',
          ),
        ),
      );
    } catch (error) {
      await _addHistory(
        type: 'cleanup',
        result: 'failed',
        title: '重试本地清理失败',
        message: userReadableErrorMessage(error),
      );
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  Future<void> _retryCleanupTask(String taskId) async {
    try {
      final cleaner = LocalCleanupExecutor(
        mappings: widget.syncRootMappings,
        uploadTasks: widget.uploadTasks,
        mediaCleaner: widget.mediaGateway,
      );
      final result = await cleaner.cleanupTask(taskId);
      await _addHistory(
        type: 'cleanup',
        result: result.pendingCount > 0 ? 'failed' : 'success',
        title: '重试单条清理任务',
        message:
            '完成 ${result.cleanedCount} 个清理任务，仍待处理 ${result.pendingCount} 个',
        relativePath: taskId,
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已重试此项清理，完成 ${result.cleanedCount} 个，仍待处理 ${result.pendingCount} 个',
          ),
        ),
      );
    } catch (error) {
      await _addHistory(
        type: 'cleanup',
        result: 'failed',
        title: '重试单条清理任务失败',
        message: userReadableErrorMessage(error),
        relativePath: taskId,
      );
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  Future<void> _ignoreCleanupTask(String taskId) async {
    try {
      final cleaner = LocalCleanupExecutor(
        mappings: widget.syncRootMappings,
        uploadTasks: widget.uploadTasks,
        mediaCleaner: widget.mediaGateway,
      );
      await cleaner.ignoreCleanupTask(taskId);
      await _addHistory(
        type: 'cleanup',
        result: 'info',
        title: '忽略本地清理提醒',
        message: '已忽略此项本地清理提醒',
        relativePath: taskId,
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已忽略此项本地清理提醒')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  Future<void> _openMediaCleanupConfirmationPage() async {
    try {
      final data = await _loadHomeData();
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => _MediaCleanupConfirmationPage(
            data: data,
            onConfirmCleanup: _confirmMediaCleanupTaskIds,
            onIgnoreOne: _ignoreCleanupTask,
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  Future<_MediaCleanupConfirmationResult> _confirmMediaCleanupTaskIds(
    List<String> taskIds,
  ) async {
    final cleaner = LocalCleanupExecutor(
      mappings: widget.syncRootMappings,
      uploadTasks: widget.uploadTasks,
      mediaCleaner: widget.mediaGateway,
    );
    final result = await cleaner.confirmMediaCleanupTasks(taskIds);
    await _addHistory(
      type: 'cleanup',
      result: result.pendingCount > 0 ? 'failed' : 'success',
      title: '确认清理本机相册资源',
      message: '已清理 ${result.cleanedCount} 个，仍待处理 ${result.pendingCount} 个',
    );
    final targetTaskIds = taskIds.toSet();
    final updatedTasks = await widget.uploadTasks.loadUploadTasks();
    final cleanedTaskIds = {
      for (final task in updatedTasks)
        if (targetTaskIds.contains(task.id) && task.status == 'deleted_local')
          task.id,
    };
    if (mounted) {
      _reloadSyncRoots();
    }
    return _MediaCleanupConfirmationResult(
      cleanedCount: result.cleanedCount,
      pendingCount: result.pendingCount,
      cleanedTaskIds: cleanedTaskIds,
    );
  }

  Future<void> _pullRemoteChanges() async {
    final executor = widget.remotePullExecutor;
    if (executor == null || _isPulling) {
      return;
    }
    setState(() {
      _isPulling = true;
    });
    try {
      final result = await executor.pullRemoteChanges();
      await _addHistory(
        type: 'pull',
        result: 'success',
        title: '拉取远端变更',
        message:
            '下载 ${result.downloadedCount} 个更新，处理 ${result.deleteCount} 个删除，保护 ${result.blockedDeleteCount} 个本地改动',
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      final blockedSuffix = result.blockedDeleteCount > 0
          ? '，其中 ${result.blockedDeleteCount} 个被本地改动保护'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已下载 ${result.downloadedCount} 个远端更新，处理 ${result.deleteCount} 个删除$blockedSuffix',
          ),
        ),
      );
    } catch (error) {
      await _addHistory(
        type: 'pull',
        result: 'failed',
        title: '拉取远端变更失败',
        message: userReadableErrorMessage(error),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userReadableErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() {
          _isPulling = false;
        });
      }
    }
  }

  Future<void> _runAutoSync({required bool scanAndUpload}) async {
    if (!mounted || _isAutoSyncing) {
      return;
    }
    final statusStore = widget.autoSyncStatus;
    final startedAt = DateTime.now().toUtc();
    var scannedCount = 0;
    var uploadedCount = 0;
    var failedCount = 0;
    var downloadedCount = 0;
    var remoteDeleteCount = 0;
    var blockedDeleteCount = 0;
    setState(() {
      _isAutoSyncing = true;
    });
    try {
      if (scanAndUpload && !_isScanning) {
        setState(() {
          _isScanning = true;
        });
        final scanner =
            widget.localScanner ??
            LocalSyncScanner(mappings: widget.syncRootMappings);
        final files = await scanner.scanMappedRoots();
        scannedCount = files.length;
        final planner = LocalUploadPlanner(uploadTasks: widget.uploadTasks);
        await planner.enqueueScannedFiles(files);
        final mediaResult = await _scanMediaBackupSources();
        scannedCount += mediaResult.scannedCount;
        if (mounted) {
          setState(() {
            _isScanning = false;
          });
        }
      }

      final uploadExecutor = widget.uploadExecutor;
      if (scanAndUpload && uploadExecutor != null && !_isUploading) {
        setState(() {
          _isUploading = true;
        });
        final result = await uploadExecutor.executePendingUploads();
        uploadedCount = result.uploadedCount;
        failedCount = result.failedCount;
        if (mounted) {
          setState(() {
            _isUploading = false;
          });
        }
      }

      final pullExecutor = widget.remotePullExecutor;
      if (pullExecutor != null && !_isPulling) {
        setState(() {
          _isPulling = true;
        });
        final result = await pullExecutor.pullRemoteChanges();
        downloadedCount = result.downloadedCount;
        remoteDeleteCount = result.deleteCount;
        blockedDeleteCount = result.blockedDeleteCount;
        if (mounted) {
          setState(() {
            _isPulling = false;
          });
        }
      }

      await statusStore?.saveAutoSyncStatus(
        AutoSyncStatus(
          lastStartedAt: startedAt,
          lastFinishedAt: DateTime.now().toUtc(),
          lastSuccessAt: DateTime.now().toUtc(),
          status: 'success',
          message: scanAndUpload ? '自动同步完成' : '启动后自动拉取完成',
          scannedCount: scannedCount,
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          downloadedCount: downloadedCount,
          remoteDeleteCount: remoteDeleteCount,
          blockedDeleteCount: blockedDeleteCount,
        ),
      );
      await _addHistory(
        type: 'auto_sync',
        result: failedCount > 0 ? 'failed' : 'success',
        title: scanAndUpload ? '自动同步完成' : '启动后自动拉取完成',
        message:
            '扫描 $scannedCount 个，上传 $uploadedCount 个，失败 $failedCount 个，下载 $downloadedCount 个，删除 $remoteDeleteCount 个',
      );
    } catch (error) {
      final message = userReadableErrorMessage(error);
      await statusStore?.saveAutoSyncStatus(
        AutoSyncStatus(
          lastStartedAt: startedAt,
          lastFinishedAt: DateTime.now().toUtc(),
          status: 'failed',
          message: message,
          scannedCount: scannedCount,
          uploadedCount: uploadedCount,
          failedCount: failedCount,
          downloadedCount: downloadedCount,
          remoteDeleteCount: remoteDeleteCount,
          blockedDeleteCount: blockedDeleteCount,
        ),
      );
      await _addHistory(
        type: 'auto_sync',
        result: 'failed',
        title: scanAndUpload ? '自动同步失败' : '启动后自动拉取失败',
        message: message,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _isUploading = false;
          _isPulling = false;
          _isAutoSyncing = false;
          _homeFuture = _loadHomeData();
        });
      }
    }
  }

  Future<MediaBackupScanResult> _scanMediaBackupSources({
    String? syncRootId,
    bool includeDisabled = false,
  }) async {
    final mediaSources = _mediaBackupSourcesStore;
    final mediaGateway = widget.mediaGateway;
    if (mediaSources == null || mediaGateway == null) {
      return const MediaBackupScanResult(scannedCount: 0, createdTaskCount: 0);
    }
    final configuredSources = await mediaSources.loadMediaBackupSources();
    final sources = [
      ...configuredSources,
      ...await _fallbackMediaBackupSources(configuredSources),
    ];
    var scannedCount = 0;
    var createdTaskCount = 0;
    final scanner = MediaBackupScanner(
      media: mediaGateway,
      uploadTasks: widget.uploadTasks,
    );
    for (final source in sources) {
      if (syncRootId != null && source.syncRootId != syncRootId) {
        continue;
      }
      if (!includeDisabled && !source.autoBackupEnabled) {
        continue;
      }
      final result = await scanner.scan(source);
      scannedCount += result.scannedCount;
      createdTaskCount += result.createdTaskCount;
    }
    return MediaBackupScanResult(
      scannedCount: scannedCount,
      createdTaskCount: createdTaskCount,
    );
  }

  Future<List<LocalMediaBackupSource>> _fallbackMediaBackupSources(
    List<LocalMediaBackupSource> configuredSources,
  ) async {
    final configuredRootIds = configuredSources
        .map((source) => source.syncRootId)
        .toSet();
    final mappings = await widget.syncRootMappings.loadSyncRootMappings();
    final now = DateTime.now().toUtc();
    return [
      for (final mapping in mappings)
        if (_isMediaBackupEncryptedPath(mapping.encryptedPath) &&
            !configuredRootIds.contains(mapping.syncRootId))
          LocalMediaBackupSource(
            id: _mediaBackupSourceId(mapping.encryptedPath),
            syncRootId: mapping.syncRootId,
            name: '相册备份',
            mediaTypes: 'image_video',
            albumScope: 'all',
            albumIds: const [],
            cleanupPolicy: mapping.cleanupPolicy,
            wifiOnly: true,
            autoBackupEnabled: true,
            createdAt: now,
            updatedAt: now,
          ),
    ];
  }

  bool _isMediaBackupEncryptedPath(String encryptedPath) {
    return encryptedPath.startsWith('media-backup:v1:');
  }

  String _mediaBackupSourceId(String encryptedPath) {
    const prefix = 'media-backup:v1:';
    if (!encryptedPath.startsWith(prefix)) {
      return encryptedPath;
    }
    final sourceId = encryptedPath.substring(prefix.length).trim();
    return sourceId.isEmpty ? encryptedPath : sourceId;
  }

  Future<void> _openSyncStatusPage() async {
    try {
      final initialData = await _homeFuture;
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => _SyncStatusPage(
            initialData: initialData,
            loadData: _loadHomeData,
            retryFailedUploads: _retryFailedUploads,
            retryCleanupPending: _retryCleanupPending,
            retryCleanupTask: _retryCleanupTask,
            ignoreCleanupTask: _ignoreCleanupTask,
            openMediaCleanupConfirmationPage: _openMediaCleanupConfirmationPage,
            enqueueConflictIssue: _enqueueConflictIssue,
            resolveIssue: _markIssueResolved,
            retryEnabled: widget.uploadExecutor != null,
            autoSyncEnabled: widget.autoSyncEnabled,
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  Future<void> _openSyncHistoryPage() async {
    final history = widget.syncHistory;
    if (history == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('同步记录暂不可用')));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _SyncHistoryPage(history: history),
      ),
    );
  }

  bool get _isMobilePlatform {
    final platform = widget.devicePlatform ?? DeviceProfile.current().platform;
    return platform == 'android' || platform == 'ios';
  }

  MediaBackupSourceStore? get _mediaBackupSourcesStore {
    if (widget.mediaBackupSources != null) {
      return widget.mediaBackupSources;
    }
    final storage = widget.storage;
    if (storage is MediaBackupSourceStore) {
      return storage as MediaBackupSourceStore;
    }
    return null;
  }

  Future<void> _openMediaBackupScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaBackupScreen(onSave: _saveMediaBackupDraft),
      ),
    );
    if (mounted) {
      _reloadSyncRoots();
    }
  }

  Future<void> _saveMediaBackupDraft(MediaBackupDraft draft) async {
    final mediaSources = _mediaBackupSourcesStore;
    if (mediaSources == null) {
      throw Exception('相册备份本地存储暂不可用');
    }
    final token = await widget.storage.loadAuthToken();
    final deviceId = await widget.storage.loadDeviceId();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('设备状态已失效');
    }
    final now = DateTime.now().toUtc();
    final sourceId = 'media-${now.microsecondsSinceEpoch}';
    final root = await widget.syncRoots.createSyncRoot(
      token: token,
      deviceId: deviceId,
      encryptedPath: 'media-backup:v1:$sourceId',
      cleanupPolicy: draft.cleanupPolicy,
      archivePath: '',
    );
    final sources = await mediaSources.loadMediaBackupSources();
    await mediaSources.saveMediaBackupSources([
      ...sources,
      LocalMediaBackupSource(
        id: sourceId,
        syncRootId: root.id,
        name: '相册备份',
        mediaTypes: draft.mediaTypes,
        albumScope: 'all',
        albumIds: const [],
        cleanupPolicy: draft.cleanupPolicy,
        wifiOnly: draft.wifiOnly,
        autoBackupEnabled: draft.autoBackupEnabled,
        createdAt: now,
        updatedAt: now,
      ),
    ]);
    await widget.syncRootMappings.saveSyncRootMapping(
      LocalSyncRootMapping(
        syncRootId: root.id,
        localPath: '',
        encryptedPath: root.encryptedPath,
        cleanupPolicy: root.cleanupPolicy,
        archivePath: root.archivePath,
      ),
    );
    await _addHistory(
      type: 'media_backup',
      result: 'success',
      title: '新增相册备份',
      message: '已添加相册备份',
      syncRootId: root.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('同步主页'),
        actions: [
          if (_isMobilePlatform)
            IconButton(
              key: const ValueKey('open_media_backup_button'),
              tooltip: '相册备份',
              onPressed: _openMediaBackupScreen,
              icon: const Icon(Icons.photo_library_outlined),
            ),
          IconButton(
            key: const ValueKey('open_sync_status_button'),
            tooltip: '同步状态',
            onPressed: _openSyncStatusPage,
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            key: const ValueKey('open_sync_history_button'),
            tooltip: '同步记录',
            onPressed: _openSyncHistoryPage,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            key: const ValueKey('scan_local_files_button'),
            tooltip: '扫描本地文件',
            onPressed: () => _scanLocalFiles(),
            icon: const Icon(Icons.search),
          ),
          IconButton(
            key: const ValueKey('execute_uploads_button'),
            tooltip: '上传待处理任务',
            onPressed: widget.uploadExecutor == null || _isUploading
                ? null
                : () => _executePendingUploads(),
            icon: const Icon(Icons.cloud_upload),
          ),
          IconButton(
            key: const ValueKey('pull_remote_changes_button'),
            tooltip: '拉取远端变更',
            onPressed: widget.remotePullExecutor == null || _isPulling
                ? null
                : _pullRemoteChanges,
            icon: const Icon(Icons.cloud_download),
          ),
          IconButton(
            key: const ValueKey('sign_out_button'),
            tooltip: '退出登录',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('add_sync_root_button'),
        onPressed: _openCreateSyncRootDialog,
        label: const Text('新增目录'),
        icon: const Icon(Icons.add),
      ),
      body: FutureBuilder<_SyncHomeData>(
        future: _homeFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            final message = userReadableErrorMessage(
              error ?? Exception('加载同步主页失败'),
            );
            final canSignOut =
                widget.onSignOut != null ||
                error is ApiException && error.statusCode == 401;
            return _SyncErrorView(
              message: message,
              canSignOut: canSignOut,
              onSignOut: _signOut,
            );
          }
          final data = snapshot.data ?? const _SyncHomeData();
          final roots = data.roots;
          final issues = data.openIssues;
          if (roots.isEmpty && issues.isEmpty) {
            return const Center(child: Text('暂无同步目录'));
          }
          final rootViews = data.rootViews;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
            children: [
              if (issues.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                  child: Text(
                    '待处理问题 ${issues.length} 个',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final issue in issues)
                  ListTile(
                    title: Text(issue.message),
                    subtitle: Text(issue.relativePath),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_syncIssueTypeLabel(issue.type)),
                        if (issue.type == 'download_conflict')
                          IconButton(
                            key: ValueKey('enqueue_conflict_issue_${issue.id}'),
                            tooltip: '加入上传队列',
                            onPressed: () => _enqueueConflictIssue(issue),
                            icon: const Icon(Icons.cloud_upload),
                          ),
                        IconButton(
                          key: ValueKey('resolve_sync_issue_${issue.id}'),
                          tooltip: '标记已处理',
                          onPressed: () => _markIssueResolved(issue.id),
                          icon: const Icon(Icons.check),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 1),
              ],
              if (rootViews.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('暂无同步目录'),
                )
              else
                for (final rootView in rootViews)
                  _SyncRootPanel(
                    rootView: rootView,
                    initiallyExpanded: rootViews.length == 1,
                    onManage: () => _openManageSyncRootDialog(rootView),
                    onScan: () => _scanLocalFiles(syncRootId: rootView.root.id),
                    onBind: () => _bindLocalFolder(rootView),
                    onUpload: widget.uploadExecutor == null || _isUploading
                        ? null
                        : () => _executePendingUploads(
                            syncRootId: rootView.root.id,
                          ),
                    onRetryFailed:
                        widget.uploadExecutor == null ||
                            _isUploading ||
                            rootView.failedTaskCount == 0
                        ? null
                        : () =>
                              _retryFailedUploads(syncRootId: rootView.root.id),
                    onDeleteFile: (file) => _deleteRemoteFile(rootView, file),
                    onDeleteFolder: (folderPath) =>
                        _deleteRemoteFolder(rootView, folderPath),
                  ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _markIssueResolved(String issueId) async {
    await widget.syncIssues?.markSyncIssueResolved(issueId: issueId);
    await _addHistory(
      type: 'issue',
      result: 'info',
      title: '关闭同步问题提醒',
      message: '已关闭一个同步问题提醒',
      relativePath: issueId,
    );
    if (!mounted) {
      return;
    }
    _reloadSyncRoots();
  }

  Future<void> _enqueueConflictIssue(LocalSyncIssue issue) async {
    try {
      final syncIssues = widget.syncIssues;
      if (syncIssues == null) {
        throw Exception('本地问题存储不可用');
      }
      final resolver = LocalSyncIssueResolver(
        mappings: widget.syncRootMappings,
        uploadTasks: widget.uploadTasks,
        syncIssues: syncIssues,
      );
      await resolver.enqueueConflictForUpload(issue);
      await _addHistory(
        type: 'issue',
        result: 'success',
        title: '上传冲突副本',
        message: '已将冲突副本加入上传队列',
        syncRootId: issue.syncRootId,
        relativePath: issue.relativePath,
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已将冲突副本加入上传队列')));
    } catch (error) {
      await _addHistory(
        type: 'issue',
        result: 'failed',
        title: '上传冲突副本失败',
        message: userReadableErrorMessage(error),
        syncRootId: issue.syncRootId,
        relativePath: issue.relativePath,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userReadableErrorMessage(error))));
    }
  }

  Future<void> _bindLocalFolder(_SyncRootViewData rootView) async {
    try {
      final localPath = await widget.folderPicker.chooseSyncFolder();
      if (localPath == null || localPath.trim().isEmpty) {
        return;
      }
      final selectedPath = localPath.trim();
      final protectedPath = widget.pathProtector.protectLocalPath(selectedPath);
      if (_shouldValidateProtectedPath(rootView.root.encryptedPath) &&
          protectedPath != rootView.root.encryptedPath) {
        throw Exception('选择的本地目录与该同步目录不匹配，请选择原来的同步目录');
      }
      await widget.syncRootMappings.saveSyncRootMapping(
        LocalSyncRootMapping(
          syncRootId: rootView.root.id,
          localPath: selectedPath,
          encryptedPath: rootView.root.encryptedPath,
          cleanupPolicy: rootView.root.cleanupPolicy,
          archivePath: rootView.root.archivePath,
        ),
      );
      await _addHistory(
        type: 'sync_root',
        result: 'success',
        title: '绑定本地目录',
        message: '已为同步目录绑定本地路径',
        syncRootId: rootView.root.id,
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已绑定本地目录')));
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message ?? '无法打开目录选择器')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  bool _shouldValidateProtectedPath(String encryptedPath) {
    return encryptedPath.startsWith('vaultsync-path:v1:');
  }

  Future<void> _deleteRemoteFile(
    _SyncRootViewData rootView,
    _UnifiedFileRecord file,
  ) async {
    final backup = file.backup;
    if (backup == null) {
      _showErrorSnackBar(Exception('这个文件还没有服务器备份，暂时不能从服务器删除'));
      return;
    }
    final confirmed = await _confirmRemoteDelete(
      title: '删除服务器备份',
      message: '将从服务器删除“${file.path}”的备份记录。本机文件不会被直接删除。',
      confirmLabel: '删除备份',
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _deleteRemoteObjects(rootView, [backup.objectId]);
  }

  Future<void> _deleteRemoteFolder(
    _SyncRootViewData rootView,
    String folderPath,
  ) async {
    final prefix = '$folderPath/';
    final objectIds = [
      for (final file in rootView.fileEntries)
        if (file.backup != null &&
            (file.path == folderPath || file.path.startsWith(prefix)))
          file.backup!.objectId,
    ];
    if (objectIds.isEmpty) {
      _showErrorSnackBar(Exception('这个文件夹下没有可删除的服务器备份'));
      return;
    }
    final confirmed = await _confirmRemoteDelete(
      title: '删除文件夹备份',
      message:
          '将从服务器删除“$folderPath”下 ${objectIds.length} 个文件的备份记录。本机文件不会被直接删除。',
      confirmLabel: '删除备份',
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _deleteRemoteObjects(rootView, objectIds);
  }

  Future<bool> _confirmRemoteDelete({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _deleteRemoteObjects(
    _SyncRootViewData rootView,
    List<String> objectIds,
  ) async {
    final gateway = widget.remoteObjectDeletes;
    if (gateway == null) {
      _showErrorSnackBar(Exception('当前客户端未启用删除能力'));
      return;
    }
    try {
      final token = await widget.storage.loadAuthToken();
      final deviceId = await widget.storage.loadDeviceId();
      if (token == null || token.isEmpty) {
        throw Exception('登录状态已失效');
      }
      if (deviceId == null || deviceId.isEmpty) {
        throw Exception('设备状态已失效');
      }
      for (final objectId in objectIds.toSet()) {
        await gateway.deleteRemoteObject(
          token: token,
          deviceId: deviceId,
          syncRootId: rootView.root.id,
          objectId: objectId,
        );
      }
      await _addHistory(
        type: 'delete',
        result: 'success',
        title: '删除服务器备份',
        message: '已删除 ${objectIds.toSet().length} 个服务器备份',
        syncRootId: rootView.root.id,
      );
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除 ${objectIds.toSet().length} 个服务器备份')),
      );
    } catch (error) {
      await _addHistory(
        type: 'delete',
        result: 'failed',
        title: '删除服务器备份失败',
        message: userReadableErrorMessage(error),
        syncRootId: rootView.root.id,
      );
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  Future<void> _openManageSyncRootDialog(_SyncRootViewData rootView) async {
    final action = await showDialog<_ManagedSyncRootAction>(
      context: context,
      builder: (context) => _ManageSyncRootDialog(rootView: rootView),
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case _UpdateSyncRootPolicyAction(:final cleanupPolicy):
        await _updateSyncRootPolicy(rootView, cleanupPolicy);
      case _DeleteSyncRootAction(:final deleteRemote):
        await _deleteSyncRoot(rootView.root.id, deleteRemote: deleteRemote);
    }
  }

  Future<void> _updateSyncRootPolicy(
    _SyncRootViewData rootView,
    String cleanupPolicy,
  ) async {
    try {
      final token = await widget.storage.loadAuthToken();
      if (token == null || token.isEmpty) {
        throw Exception('登录状态已失效');
      }
      final updated = await widget.syncRoots.updateSyncRootCleanupPolicy(
        token: token,
        syncRootId: rootView.root.id,
        cleanupPolicy: cleanupPolicy,
      );
      final mappings = await widget.syncRootMappings.loadSyncRootMappings();
      await widget.syncRootMappings.saveSyncRootMappings([
        for (final mapping in mappings)
          if (mapping.syncRootId == updated.id)
            LocalSyncRootMapping(
              syncRootId: mapping.syncRootId,
              localPath: mapping.localPath,
              encryptedPath: mapping.encryptedPath,
              cleanupPolicy: updated.cleanupPolicy,
              archivePath: updated.archivePath,
            )
          else
            mapping,
      ]);
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  Future<void> _deleteSyncRoot(
    String syncRootId, {
    required bool deleteRemote,
  }) async {
    try {
      final token = await widget.storage.loadAuthToken();
      if (token == null || token.isEmpty) {
        throw Exception('登录状态已失效');
      }
      await widget.syncRoots.deleteSyncRoot(
        token: token,
        syncRootId: syncRootId,
        deleteRemote: deleteRemote,
      );
      final mappings = await widget.syncRootMappings.loadSyncRootMappings();
      await widget.syncRootMappings.saveSyncRootMappings([
        for (final mapping in mappings)
          if (mapping.syncRootId != syncRootId) mapping,
      ]);
      final tasks = await widget.uploadTasks.loadUploadTasks();
      await widget.uploadTasks.saveUploadTasks([
        for (final task in tasks)
          if (task.syncRootId != syncRootId) task,
      ]);
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error);
    }
  }

  void _showErrorSnackBar(Object error) {
    final message = userReadableErrorMessage(error);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

LocalUploadTask _copyUploadTask(
  LocalUploadTask task, {
  String? status,
  int? attempts,
  String? lastError,
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
    status: status ?? task.status,
    attempts: attempts ?? task.attempts,
    createdAt: task.createdAt,
    lastError: lastError ?? task.lastError,
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

class _SyncHomeData {
  final List<SyncRoot> roots;
  final List<LocalSyncRootMapping> mappings;
  final List<LocalUploadTask> uploadTasks;
  final List<LocalSyncIssue> issues;
  final Map<String, List<RemoteBackupEntry>> remoteBackupEntries;
  final AutoSyncStatus autoSyncStatus;

  const _SyncHomeData({
    this.roots = const [],
    this.mappings = const [],
    this.uploadTasks = const [],
    this.issues = const [],
    this.remoteBackupEntries = const {},
    this.autoSyncStatus = const AutoSyncStatus(),
  });

  List<LocalSyncIssue> get openIssues {
    return [
      for (final issue in issues)
        if (issue.status == 'open') issue,
    ];
  }

  List<_SyncRootViewData> get rootViews {
    return [
      for (final root in roots)
        _SyncRootViewData(
          root: root,
          mapping: _mappingFor(root.id),
          tasks: [
            for (final task in uploadTasks)
              if (task.syncRootId == root.id) task,
          ],
          issues: [
            for (final issue in openIssues)
              if (issue.syncRootId == root.id) issue,
          ],
          remoteBackups: remoteBackupEntries[root.id] ?? const [],
        ),
    ];
  }

  int get pendingTaskCount {
    return uploadTasks.where((task) => task.status == 'pending').length;
  }

  int get failedTaskCount {
    return uploadTasks.where((task) => task.status == 'failed').length;
  }

  int get cleanupPendingTaskCount {
    return uploadTasks.where((task) => task.status == 'cleanup_pending').length;
  }

  int get fileCleanupPendingTaskCount {
    return uploadTasks
        .where(
          (task) =>
              task.status == 'cleanup_pending' &&
              task.sourceType != 'media_asset',
        )
        .length;
  }

  int get activeTaskCount {
    return uploadTasks
        .where(
          (task) =>
              task.status == 'pending' || task.status == 'cleanup_pending',
        )
        .length;
  }

  int get backedUpDeletedLocalCount {
    return uploadTasks.where((task) => task.status == 'deleted_local').length;
  }

  int get remoteBackupCount {
    return remoteBackupEntries.values.fold(
      0,
      (total, entries) => total + entries.length,
    );
  }

  int get fileEntryCount {
    return rootViews.fold(
      0,
      (total, rootView) => total + rootView.fileEntries.length,
    );
  }

  LocalSyncRootMapping? _mappingFor(String syncRootId) {
    for (final mapping in mappings) {
      if (mapping.syncRootId == syncRootId) {
        return mapping;
      }
    }
    return null;
  }
}

class _PrunedLocalSyncState {
  final List<LocalSyncRootMapping> mappings;
  final List<LocalUploadTask> uploadTasks;

  const _PrunedLocalSyncState({
    required this.mappings,
    required this.uploadTasks,
  });
}

class _SyncErrorView extends StatelessWidget {
  final String message;
  final bool canSignOut;
  final Future<void> Function() onSignOut;

  const _SyncErrorView({
    required this.message,
    required this.canSignOut,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 36),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (canSignOut) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('error_sign_out_button'),
                onPressed: onSignOut,
                icon: const Icon(Icons.logout),
                label: const Text('返回登录'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SyncStatusPage extends StatefulWidget {
  final _SyncHomeData initialData;
  final Future<_SyncHomeData> Function() loadData;
  final Future<void> Function({String? syncRootId}) retryFailedUploads;
  final Future<void> Function() retryCleanupPending;
  final Future<void> Function(String taskId) retryCleanupTask;
  final Future<void> Function(String taskId) ignoreCleanupTask;
  final Future<void> Function() openMediaCleanupConfirmationPage;
  final Future<void> Function(LocalSyncIssue issue) enqueueConflictIssue;
  final Future<void> Function(String issueId) resolveIssue;
  final bool retryEnabled;
  final bool autoSyncEnabled;

  const _SyncStatusPage({
    required this.initialData,
    required this.loadData,
    required this.retryFailedUploads,
    required this.retryCleanupPending,
    required this.retryCleanupTask,
    required this.ignoreCleanupTask,
    required this.openMediaCleanupConfirmationPage,
    required this.enqueueConflictIssue,
    required this.resolveIssue,
    required this.retryEnabled,
    required this.autoSyncEnabled,
  });

  @override
  State<_SyncStatusPage> createState() => _SyncStatusPageState();
}

class _SyncStatusPageState extends State<_SyncStatusPage> {
  late Future<_SyncHomeData> _future;
  var _isRetrying = false;

  @override
  void initState() {
    super.initState();
    _future = Future.value(widget.initialData);
  }

  void _refresh() {
    setState(() {
      _future = widget.loadData();
    });
  }

  Future<void> _retryFailed({String? syncRootId}) async {
    if (_isRetrying) {
      return;
    }
    setState(() {
      _isRetrying = true;
    });
    try {
      await widget.retryFailedUploads(syncRootId: syncRootId);
      if (!mounted) {
        return;
      }
      _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  Future<void> _retryCleanup() async {
    if (_isRetrying) {
      return;
    }
    setState(() {
      _isRetrying = true;
    });
    try {
      await widget.retryCleanupPending();
      if (!mounted) {
        return;
      }
      _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  Future<void> _retryOneCleanup(String taskId) async {
    if (_isRetrying) {
      return;
    }
    setState(() {
      _isRetrying = true;
    });
    try {
      await widget.retryCleanupTask(taskId);
      if (!mounted) {
        return;
      }
      _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  Future<void> _ignoreOneCleanup(String taskId) async {
    if (_isRetrying) {
      return;
    }
    setState(() {
      _isRetrying = true;
    });
    try {
      await widget.ignoreCleanupTask(taskId);
      if (!mounted) {
        return;
      }
      _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  Future<void> _openMediaCleanupPage() async {
    await widget.openMediaCleanupConfirmationPage();
    if (!mounted) {
      return;
    }
    _refresh();
  }

  Future<void> _openIssueDetail(
    _SyncHomeData data,
    LocalSyncIssue issue,
  ) async {
    var rootName = issue.syncRootId;
    for (final rootView in data.rootViews) {
      if (rootView.root.id == issue.syncRootId) {
        rootName = rootView.displayName;
        break;
      }
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _SyncIssueDetailPage(
          issue: issue,
          rootName: rootName,
          onEnqueueConflict: widget.enqueueConflictIssue,
          onResolve: widget.resolveIssue,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('同步状态'),
        actions: [
          IconButton(
            key: const ValueKey('refresh_sync_status_button'),
            tooltip: '刷新状态',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<_SyncHomeData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(userReadableErrorMessage(snapshot.error!)),
              ),
            );
          }
          final data = snapshot.data ?? widget.initialData;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              _SyncStatusCenter(
                data: data,
                retryEnabled: widget.retryEnabled && !_isRetrying,
                onRetryFailed: () => _retryFailed(),
                onRetryCleanup: _isRetrying ? null : _retryCleanup,
                autoSyncEnabled: widget.autoSyncEnabled,
              ),
              const SizedBox(height: 12),
              _FailedUploadTaskList(
                data: data,
                retryEnabled: widget.retryEnabled && !_isRetrying,
                onRetryRoot: (syncRootId) =>
                    _retryFailed(syncRootId: syncRootId),
              ),
              const SizedBox(height: 12),
              _CleanupPendingTaskList(
                data: data,
                onOpenMediaCleanupPage: _openMediaCleanupPage,
                onRetryCleanup: _isRetrying ? null : _retryCleanup,
                onRetryOne: _isRetrying ? null : _retryOneCleanup,
                onIgnoreOne: _isRetrying ? null : _ignoreOneCleanup,
              ),
              const SizedBox(height: 12),
              _OpenSyncIssueList(
                data: data,
                onOpenIssue: (issue) => _openIssueDetail(data, issue),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SyncStatusCenter extends StatelessWidget {
  final _SyncHomeData data;
  final bool retryEnabled;
  final VoidCallback onRetryFailed;
  final VoidCallback? onRetryCleanup;
  final bool autoSyncEnabled;

  const _SyncStatusCenter({
    required this.data,
    required this.retryEnabled,
    required this.onRetryFailed,
    required this.onRetryCleanup,
    required this.autoSyncEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('sync_status_center'),
      margin: const EdgeInsets.fromLTRB(4, 2, 4, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sync, size: 18, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text('同步状态', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text(
                _overallStatusLabel(data),
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusMetric(
                icon: Icons.cloud_upload_outlined,
                label: '待上传',
                value: data.pendingTaskCount,
              ),
              _StatusMetric(
                icon: Icons.error_outline,
                label: '上传失败',
                value: data.failedTaskCount,
              ),
              _StatusMetric(
                icon: Icons.cleaning_services_outlined,
                label: '待清理',
                value: data.cleanupPendingTaskCount,
              ),
              _StatusMetric(
                icon: Icons.report_problem_outlined,
                label: '待处理问题',
                value: data.openIssues.length,
              ),
              if (data.failedTaskCount > 0)
                OutlinedButton.icon(
                  key: const ValueKey('retry_failed_uploads_button'),
                  onPressed: retryEnabled ? onRetryFailed : null,
                  icon: const Icon(Icons.refresh),
                  label: Text('重试 ${data.failedTaskCount} 个失败任务'),
                ),
              if (data.fileCleanupPendingTaskCount > 0)
                OutlinedButton.icon(
                  key: const ValueKey('retry_cleanup_pending_button'),
                  onPressed: onRetryCleanup,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: Text('重试 ${data.fileCleanupPendingTaskCount} 个清理任务'),
                ),
            ],
          ),
          if (data.rootViews.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final rootView in data.rootViews)
              _RootStatusLine(rootView: rootView),
          ],
          const SizedBox(height: 10),
          _AutoSyncStatusLine(
            status: data.autoSyncStatus,
            enabled: autoSyncEnabled,
          ),
        ],
      ),
    );
  }

  String _overallStatusLabel(_SyncHomeData data) {
    if (data.failedTaskCount > 0) {
      return '需要重试';
    }
    if (data.openIssues.isNotEmpty) {
      return '有待处理问题';
    }
    if (data.pendingTaskCount > 0) {
      return '等待上传';
    }
    if (data.cleanupPendingTaskCount > 0) {
      return '等待清理';
    }
    return '当前正常';
  }
}

class _SyncHistoryPage extends StatefulWidget {
  final SyncHistoryStore history;

  const _SyncHistoryPage({required this.history});

  @override
  State<_SyncHistoryPage> createState() => _SyncHistoryPageState();
}

class _SyncHistoryPageState extends State<_SyncHistoryPage> {
  late Future<List<LocalSyncHistoryEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.history.loadSyncHistory();
  }

  void _refresh() {
    setState(() {
      _future = widget.history.loadSyncHistory();
    });
  }

  Future<void> _clearHistory() async {
    await widget.history.clearSyncHistory();
    if (!mounted) {
      return;
    }
    _refresh();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已清空同步记录')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('同步记录'),
        actions: [
          IconButton(
            key: const ValueKey('clear_sync_history_button'),
            tooltip: '清空记录',
            onPressed: _clearHistory,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: FutureBuilder<List<LocalSyncHistoryEntry>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(userReadableErrorMessage(snapshot.error!)),
              ),
            );
          }
          final items = snapshot.data ?? const [];
          if (items.isEmpty) {
            return const Center(child: Text('暂无同步记录'));
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              return _SyncHistoryTile(entry: items[index]);
            },
          );
        },
      ),
    );
  }
}

class _SyncHistoryTile extends StatelessWidget {
  final LocalSyncHistoryEntry entry;

  const _SyncHistoryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final details = <String>[
      _formatDateTime(entry.createdAt),
      if (entry.relativePath.trim().isNotEmpty) entry.relativePath.trim(),
      if (entry.syncRootId.trim().isNotEmpty)
        '目录 ${_shortId(entry.syncRootId)}',
    ];
    return ListTile(
      leading: Icon(
        _historyIcon(entry.type),
        color: _historyColor(colorScheme, entry.result),
      ),
      title: Text(entry.title),
      subtitle: Text([entry.message, ...details].join(' · ')),
      trailing: _HistoryResultBadge(result: entry.result),
    );
  }
}

class _HistoryResultBadge extends StatelessWidget {
  final String result;

  const _HistoryResultBadge({required this.result});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _historyColor(colorScheme, result).withValues(alpha: 0.10),
        border: Border.all(color: _historyColor(colorScheme, result)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _historyResultLabel(result),
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _AutoSyncStatusLine extends StatelessWidget {
  final AutoSyncStatus status;
  final bool enabled;

  const _AutoSyncStatusLine({required this.status, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          enabled ? Icons.schedule_outlined : Icons.pause_circle_outline,
          size: 16,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(_autoSyncSummary(status, enabled: enabled), style: style),
        ),
      ],
    );
  }
}

class _FailedUploadTaskList extends StatelessWidget {
  final _SyncHomeData data;
  final bool retryEnabled;
  final ValueChanged<String> onRetryRoot;

  const _FailedUploadTaskList({
    required this.data,
    required this.retryEnabled,
    required this.onRetryRoot,
  });

  @override
  Widget build(BuildContext context) {
    final failedItems = <({String rootName, LocalUploadTask task})>[
      for (final rootView in data.rootViews)
        for (final task in rootView.tasks)
          if (task.status == 'failed')
            (rootName: rootView.displayName, task: task),
    ];
    if (failedItems.isEmpty) {
      return const _StatusEmptyState();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: Text(
            '失败任务 ${failedItems.length} 个',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final item in failedItems)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(item.task.relativePath),
              subtitle: Text(
                [
                  item.rootName,
                  '已尝试 ${item.task.attempts} 次',
                  if (item.task.lastError.trim().isNotEmpty)
                    item.task.lastError.trim(),
                ].join(' · '),
              ),
              trailing: TextButton.icon(
                onPressed: retryEnabled
                    ? () => onRetryRoot(item.task.syncRootId)
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('重试此目录'),
              ),
            ),
          ),
      ],
    );
  }
}

class _CleanupPendingTaskList extends StatelessWidget {
  final _SyncHomeData data;
  final VoidCallback onOpenMediaCleanupPage;
  final VoidCallback? onRetryCleanup;
  final ValueChanged<String>? onRetryOne;
  final ValueChanged<String>? onIgnoreOne;

  const _CleanupPendingTaskList({
    required this.data,
    required this.onOpenMediaCleanupPage,
    required this.onRetryCleanup,
    required this.onRetryOne,
    required this.onIgnoreOne,
  });

  @override
  Widget build(BuildContext context) {
    final mediaCleanupItems = <({String rootName, LocalUploadTask task})>[
      for (final rootView in data.rootViews)
        for (final task in rootView.tasks)
          if (task.status == 'cleanup_pending' &&
              task.sourceType == 'media_asset')
            (rootName: rootView.displayName, task: task),
    ];
    final fileCleanupItems = <({String rootName, LocalUploadTask task})>[
      for (final rootView in data.rootViews)
        for (final task in rootView.tasks)
          if (task.status == 'cleanup_pending' &&
              task.sourceType != 'media_asset')
            (rootName: rootView.displayName, task: task),
    ];
    if (mediaCleanupItems.isEmpty && fileCleanupItems.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mediaCleanupItems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '待清理照片和视频 ${mediaCleanupItems.length} 个',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('open_media_cleanup_page_button'),
                  onPressed: onOpenMediaCleanupPage,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('查看待清理照片和视频'),
                ),
              ],
            ),
          ),
        if (fileCleanupItems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '待清理任务 ${fileCleanupItems.length} 个',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('retry_cleanup_pending_list_button'),
                  onPressed: onRetryCleanup,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试清理'),
                ),
              ],
            ),
          ),
        for (final item in fileCleanupItems)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: Text(item.task.relativePath),
              subtitle: Text(
                [
                  item.rootName,
                  item.task.localPath,
                  if (item.task.lastError.trim().isNotEmpty)
                    item.task.lastError.trim()
                  else
                    '等待确认后清理本地文件',
                ].join(' · '),
              ),
              trailing: PopupMenuButton<_CleanupTaskAction>(
                key: ValueKey('cleanup_task_actions_${item.task.id}'),
                tooltip: '清理任务操作',
                onSelected: (action) {
                  switch (action) {
                    case _CleanupTaskAction.retry:
                      onRetryOne?.call(item.task.id);
                    case _CleanupTaskAction.ignore:
                      onIgnoreOne?.call(item.task.id);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _CleanupTaskAction.retry,
                    enabled: onRetryOne != null,
                    child: const Text('重试此项'),
                  ),
                  PopupMenuItem(
                    value: _CleanupTaskAction.ignore,
                    enabled: onIgnoreOne != null,
                    child: const Text('忽略此项'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

enum _CleanupTaskAction { retry, ignore }

class _MediaCleanupConfirmationResult {
  final int cleanedCount;
  final int pendingCount;
  final Set<String> cleanedTaskIds;

  const _MediaCleanupConfirmationResult({
    required this.cleanedCount,
    required this.pendingCount,
    required this.cleanedTaskIds,
  });
}

class _MediaCleanupConfirmationPage extends StatefulWidget {
  final _SyncHomeData data;
  final Future<_MediaCleanupConfirmationResult> Function(List<String> taskIds)
  onConfirmCleanup;
  final Future<void> Function(String taskId)? onIgnoreOne;

  const _MediaCleanupConfirmationPage({
    required this.data,
    required this.onConfirmCleanup,
    this.onIgnoreOne,
  });

  @override
  State<_MediaCleanupConfirmationPage> createState() =>
      _MediaCleanupConfirmationPageState();
}

class _MediaCleanupConfirmationPageState
    extends State<_MediaCleanupConfirmationPage> {
  static const _maxCleanupCount = 10;

  final Set<String> _selectedTaskIds = {};
  final Set<String> _completedTaskIds = {};
  final Set<String> _ignoredTaskIds = {};
  var _isConfirming = false;

  List<({String rootName, LocalUploadTask task})> get _mediaCleanupItems {
    return [
      for (final rootView in widget.data.rootViews)
        for (final task in rootView.tasks)
          if (task.sourceType == 'media_asset' &&
              task.status == 'cleanup_pending' &&
              !_completedTaskIds.contains(task.id) &&
              !_ignoredTaskIds.contains(task.id))
            (rootName: rootView.displayName, task: task),
    ];
  }

  void _toggleSelection(String taskId) {
    setState(() {
      if (_selectedTaskIds.contains(taskId)) {
        _selectedTaskIds.remove(taskId);
        return;
      }
      if (_selectedTaskIds.length >= _maxCleanupCount) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('第一版每次最多清理 10 个，请分批处理。')));
        return;
      }
      _selectedTaskIds.add(taskId);
    });
  }

  Future<void> _ignoreTask(String taskId) async {
    final onIgnoreOne = widget.onIgnoreOne;
    if (onIgnoreOne == null) {
      return;
    }
    await onIgnoreOne(taskId);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedTaskIds.remove(taskId);
      _ignoredTaskIds.add(taskId);
    });
  }

  Future<void> _confirmSelected() async {
    if (_selectedTaskIds.isEmpty || _isConfirming) {
      return;
    }
    final selectedTaskIds = _selectedTaskIds.toList(growable: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除本机相册资源？'),
        content: const Text('确认后将删除所选照片和视频的本机相册资源。服务器上的加密备份不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm_media_cleanup_dialog_button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _isConfirming = true;
    });
    try {
      final result = await widget.onConfirmCleanup(selectedTaskIds);
      if (!mounted) {
        return;
      }
      final remainingCount = _mediaCleanupItems
          .where((item) => !result.cleanedTaskIds.contains(item.task.id))
          .length;
      setState(() {
        _selectedTaskIds.clear();
        _completedTaskIds.addAll(result.cleanedTaskIds);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已清理 ${result.cleanedCount} 个，仍待处理 $remainingCount 个'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userReadableErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() {
          _isConfirming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _mediaCleanupItems;
    final selectedCount = _selectedTaskIds.length;
    return Scaffold(
      appBar: AppBar(title: const Text('待清理照片和视频')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          Text(
            '这些照片和视频已经上传到 VaultSync 服务器。确认清理只会删除本机相册资源，不会删除服务器上的加密备份。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusBadge(label: '待清理总数 ${items.length}'),
              _StatusBadge(label: '当前已选择 $selectedCount'),
              _StatusBadge(label: '本次最多可清理数量：$_maxCleanupCount'),
            ],
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('暂无待清理照片和视频')),
            )
          else
            for (final item in items)
              Card(
                key: ValueKey('media_cleanup_select_${item.task.id}'),
                margin: const EdgeInsets.symmetric(vertical: 4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListTile(
                  onTap: _isConfirming
                      ? null
                      : () => _toggleSelection(item.task.id),
                  leading: Checkbox(
                    value: _selectedTaskIds.contains(item.task.id),
                    onChanged: _isConfirming
                        ? null
                        : (_) => _toggleSelection(item.task.id),
                  ),
                  title: Text(item.task.relativePath),
                  subtitle: Text(
                    [
                      item.rootName,
                      item.task.assetMediaType.isEmpty
                          ? '相册资源'
                          : item.task.assetMediaType,
                      if (item.task.lastError.trim().isNotEmpty)
                        item.task.lastError.trim(),
                    ].join(' · '),
                  ),
                  trailing: widget.onIgnoreOne == null
                      ? null
                      : IconButton(
                          tooltip: '忽略此项',
                          onPressed: _isConfirming
                              ? null
                              : () => _ignoreTask(item.task.id),
                          icon: const Icon(Icons.visibility_off_outlined),
                        ),
                ),
              ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: FilledButton.icon(
          key: const ValueKey('confirm_media_cleanup_button'),
          onPressed: selectedCount == 0 || _isConfirming
              ? null
              : _confirmSelected,
          icon: _isConfirming
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_outline),
          label: Text(
            selectedCount == 0 ? '请选择要清理的项目' : '确认清理 $selectedCount 个',
          ),
        ),
      ),
    );
  }
}

class _OpenSyncIssueList extends StatelessWidget {
  final _SyncHomeData data;
  final ValueChanged<LocalSyncIssue> onOpenIssue;

  const _OpenSyncIssueList({required this.data, required this.onOpenIssue});

  @override
  Widget build(BuildContext context) {
    final issues = data.openIssues;
    if (issues.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: Text(
            '待处理问题 ${issues.length} 个',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final issue in issues)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListTile(
              key: ValueKey('sync_issue_${issue.id}'),
              leading: const Icon(Icons.report_problem_outlined),
              title: Text(issue.relativePath),
              subtitle: Text(
                [
                  _syncIssueTypeLabel(issue.type),
                  issue.message,
                  if (issue.localPath.trim().isNotEmpty) issue.localPath,
                ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpenIssue(issue),
            ),
          ),
      ],
    );
  }
}

class _SyncIssueDetailPage extends StatefulWidget {
  final LocalSyncIssue issue;
  final String rootName;
  final Future<void> Function(LocalSyncIssue issue) onEnqueueConflict;
  final Future<void> Function(String issueId) onResolve;

  const _SyncIssueDetailPage({
    required this.issue,
    required this.rootName,
    required this.onEnqueueConflict,
    required this.onResolve,
  });

  @override
  State<_SyncIssueDetailPage> createState() => _SyncIssueDetailPageState();
}

class _SyncIssueDetailPageState extends State<_SyncIssueDetailPage> {
  var _isSubmitting = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_isSubmitting) {
      return;
    }
    setState(() {
      _isSubmitting = true;
    });
    try {
      await action();
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userReadableErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final issue = widget.issue;
    return Scaffold(
      appBar: AppBar(title: const Text('问题详情')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _IssueDetailHeader(issue: issue),
          const SizedBox(height: 12),
          _IssueDetailRow(label: '同步目录', value: widget.rootName),
          _IssueDetailRow(
            label: '问题类型',
            value: _syncIssueTypeLabel(issue.type),
          ),
          _IssueDetailRow(label: '文件路径', value: issue.relativePath),
          if (issue.localPath.trim().isNotEmpty)
            _IssueDetailRow(label: '本地路径', value: issue.localPath),
          _IssueDetailRow(label: '说明', value: issue.message),
          _IssueDetailRow(
            label: '创建时间',
            value: _formatDateTime(issue.createdAt),
          ),
          const SizedBox(height: 16),
          if (issue.type == 'download_conflict')
            FilledButton.icon(
              key: const ValueKey('enqueue_conflict_from_detail_button'),
              onPressed: _isSubmitting
                  ? null
                  : () => _run(() => widget.onEnqueueConflict(issue)),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('上传冲突副本'),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('resolve_issue_from_detail_button'),
            onPressed: _isSubmitting
                ? null
                : () => _run(() => widget.onResolve(issue.id)),
            icon: const Icon(Icons.check),
            label: Text(_issueResolveActionLabel(issue.type)),
          ),
        ],
      ),
    );
  }
}

String _issueResolveActionLabel(String type) {
  return switch (type) {
    'download_conflict' => '暂不处理，关闭提醒',
    'remote_delete_blocked' => '保留本地文件，关闭提醒',
    _ => '标记已处理',
  };
}

class _IssueDetailHeader extends StatelessWidget {
  final LocalSyncIssue issue;

  const _IssueDetailHeader({required this.issue});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.report_problem_outlined, color: colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _syncIssueTypeLabel(issue.type),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _IssueDetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _IssueDetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }
}

class _StatusEmptyState extends StatelessWidget {
  const _StatusEmptyState();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 2, 4, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.check_circle_outline),
          SizedBox(width: 8),
          Expanded(child: Text('暂无失败任务')),
        ],
      ),
    );
  }
}

class _StatusMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;

  const _StatusMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 5),
          Text('$label：$value'),
        ],
      ),
    );
  }
}

class _RootStatusLine extends StatelessWidget {
  final _SyncRootViewData rootView;

  const _RootStatusLine({required this.rootView});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              rootView.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          Text(
            '待上传 ${rootView.pendingTaskCount} · 失败 ${rootView.failedTaskCount} · 问题 ${rootView.issues.length}',
            style: style,
          ),
        ],
      ),
    );
  }
}

class _SyncRootPanel extends StatelessWidget {
  final _SyncRootViewData rootView;
  final bool initiallyExpanded;
  final VoidCallback onManage;
  final VoidCallback onScan;
  final VoidCallback onBind;
  final VoidCallback? onUpload;
  final VoidCallback? onRetryFailed;
  final ValueChanged<_UnifiedFileRecord> onDeleteFile;
  final ValueChanged<String> onDeleteFolder;

  const _SyncRootPanel({
    required this.rootView,
    required this.initiallyExpanded,
    required this.onManage,
    required this.onScan,
    required this.onBind,
    required this.onUpload,
    required this.onRetryFailed,
    required this.onDeleteFile,
    required this.onDeleteFolder,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: Icon(
          Icons.folder_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(rootView.displayName),
        subtitle: Text(
          rootView.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusBadge(label: rootView.statusLabel),
            PopupMenuButton<_SyncRootQuickAction>(
              key: ValueKey('sync_root_quick_actions_${rootView.root.id}'),
              tooltip: '目录操作',
              onSelected: (action) {
                switch (action) {
                  case _SyncRootQuickAction.bind:
                    onBind();
                  case _SyncRootQuickAction.scan:
                    onScan();
                  case _SyncRootQuickAction.upload:
                    onUpload?.call();
                  case _SyncRootQuickAction.retryFailed:
                    onRetryFailed?.call();
                }
              },
              itemBuilder: (context) => [
                if (rootView.isUnbound)
                  const PopupMenuItem(
                    value: _SyncRootQuickAction.bind,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.folder_open_outlined),
                      title: Text('绑定本地目录'),
                    ),
                  ),
                const PopupMenuItem(
                  value: _SyncRootQuickAction.scan,
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.search),
                    title: Text('扫描此目录'),
                  ),
                ),
                PopupMenuItem(
                  value: _SyncRootQuickAction.upload,
                  enabled: onUpload != null,
                  child: const ListTile(
                    dense: true,
                    leading: Icon(Icons.cloud_upload_outlined),
                    title: Text('上传此目录'),
                  ),
                ),
                if (rootView.failedTaskCount > 0)
                  PopupMenuItem(
                    value: _SyncRootQuickAction.retryFailed,
                    enabled: onRetryFailed != null,
                    child: const ListTile(
                      dense: true,
                      leading: Icon(Icons.refresh),
                      title: Text('重试失败任务'),
                    ),
                  ),
              ],
            ),
            IconButton(
              key: ValueKey('manage_sync_root_${rootView.root.id}'),
              tooltip: '管理同步目录',
              onPressed: onManage,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          _RootMetaRow(rootView: rootView),
          if (rootView.shouldShowDeletePolicyNotice) ...[
            const SizedBox(height: 8),
            _DeletePolicyNotice(
              backedUpCount: rootView.backedUpDeletedLocalCount,
            ),
          ],
          const SizedBox(height: 8),
          if (rootView.fileEntries.isEmpty)
            const _EmptyFileHint()
          else
            _UnifiedFileTree(
              rootView: rootView,
              onDeleteFile: onDeleteFile,
              onDeleteFolder: onDeleteFolder,
            ),
        ],
      ),
    );
  }
}

enum _SyncRootQuickAction { bind, scan, upload, retryFailed }

class _RootMetaRow extends StatelessWidget {
  final _SyncRootViewData rootView;

  const _RootMetaRow({required this.rootView});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _MetaChip(
          icon: Icons.cleaning_services_outlined,
          label: '清理策略：${_cleanupPolicyLabel(rootView.root.cleanupPolicy)}',
        ),
        _MetaChip(
          icon: Icons.insert_drive_file_outlined,
          label: '文件：${rootView.fileEntries.length}',
        ),
        _MetaChip(
          icon: Icons.cloud_upload_outlined,
          label: '待上传：${rootView.pendingTaskCount}',
        ),
        if (rootView.failedTaskCount > 0)
          _MetaChip(
            icon: Icons.error_outline,
            label: '上传失败：${rootView.failedTaskCount}',
          ),
        if (rootView.backedUpDeletedLocalCount > 0)
          _MetaChip(
            icon: Icons.cloud_done_outlined,
            label: '本地已清理：${rootView.backedUpDeletedLocalCount}',
          ),
        _MetaChip(
          icon: Icons.error_outline,
          label: '问题：${rootView.issues.length}',
        ),
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 5),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _UnifiedFileTree extends StatefulWidget {
  final _SyncRootViewData rootView;
  final ValueChanged<_UnifiedFileRecord> onDeleteFile;
  final ValueChanged<String> onDeleteFolder;

  const _UnifiedFileTree({
    required this.rootView,
    required this.onDeleteFile,
    required this.onDeleteFolder,
  });

  @override
  State<_UnifiedFileTree> createState() => _UnifiedFileTreeState();
}

class _UnifiedFileTreeState extends State<_UnifiedFileTree> {
  final _expandedFolders = <String>{};

  void _toggleFolder(String path) {
    setState(() {
      if (!_expandedFolders.add(path)) {
        _expandedFolders.remove(path);
      }
    });
  }

  bool _isVisible(_UnifiedTreeEntry entry) {
    if (entry.depth == 0) {
      return true;
    }
    final parts = _pathParts(entry.path);
    for (var index = 0; index < parts.length - 1; index += 1) {
      final parentPath = parts.take(index + 1).join('/');
      if (!_expandedFolders.contains(parentPath)) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final folderSummaries = _UnifiedFolderSummaries.fromFiles(
      widget.rootView.fileEntries,
      widget.rootView,
    );
    return Column(
      children: [
        for (final entry in _UnifiedTreeEntry.fromFiles(
          widget.rootView.fileEntries,
        ))
          if (_isVisible(entry))
            switch (entry) {
              _UnifiedFolderEntry() => _UnifiedFolderRow(
                entry: entry,
                summary: folderSummaries.byPath[entry.path]!,
                expanded: _expandedFolders.contains(entry.path),
                onToggle: () => _toggleFolder(entry.path),
                onDelete: () => widget.onDeleteFolder(entry.path),
              ),
              _UnifiedFileEntry() => _UnifiedFileRow(
                entry: entry,
                statusLabel: widget.rootView.fileStatusLabel(entry.file),
                onDelete: () => widget.onDeleteFile(entry.file),
              ),
            },
      ],
    );
  }
}

sealed class _UnifiedTreeEntry {
  final String name;
  final String path;
  final int depth;

  const _UnifiedTreeEntry({
    required this.name,
    required this.path,
    required this.depth,
  });

  static List<_UnifiedTreeEntry> fromFiles(List<_UnifiedFileRecord> files) {
    final sorted = [...files]
      ..sort((left, right) => left.path.compareTo(right.path));
    final treeEntries = <_UnifiedTreeEntry>[];
    final seenFolders = <String>{};
    for (final file in sorted) {
      final parts = _pathParts(file.path);
      if (parts.isEmpty) {
        continue;
      }
      for (var index = 0; index < parts.length - 1; index += 1) {
        final path = parts.take(index + 1).join('/');
        if (!seenFolders.add(path)) {
          continue;
        }
        treeEntries.add(
          _UnifiedFolderEntry(name: parts[index], path: path, depth: index),
        );
      }
      treeEntries.add(
        _UnifiedFileEntry(
          name: parts.last,
          path: parts.join('/'),
          depth: parts.length - 1,
          file: file,
        ),
      );
    }
    return treeEntries;
  }
}

class _UnifiedFolderEntry extends _UnifiedTreeEntry {
  const _UnifiedFolderEntry({
    required super.name,
    required super.path,
    required super.depth,
  });
}

class _UnifiedFileEntry extends _UnifiedTreeEntry {
  final _UnifiedFileRecord file;

  const _UnifiedFileEntry({
    required super.name,
    required super.path,
    required super.depth,
    required this.file,
  });
}

class _UnifiedFolderSummaries {
  final Map<String, _UnifiedFolderSummary> byPath;

  const _UnifiedFolderSummaries({required this.byPath});

  factory _UnifiedFolderSummaries.fromFiles(
    List<_UnifiedFileRecord> files,
    _SyncRootViewData rootView,
  ) {
    final summaries = <String, _UnifiedFolderSummary>{};
    for (final file in files) {
      final parts = _pathParts(file.path);
      for (var index = 0; index < parts.length - 1; index += 1) {
        final path = parts.take(index + 1).join('/');
        final current = summaries[path];
        summaries[path] = (current ?? const _UnifiedFolderSummary()).addFile(
          _folderStatusLabel(rootView.fileStatusLabel(file)),
        );
      }
    }
    return _UnifiedFolderSummaries(byPath: summaries);
  }
}

class _UnifiedFolderSummary {
  final int fileCount;
  final String statusLabel;

  const _UnifiedFolderSummary({this.fileCount = 0, this.statusLabel = '已同步'});

  _UnifiedFolderSummary addFile(String nextStatusLabel) {
    return _UnifiedFolderSummary(
      fileCount: fileCount + 1,
      statusLabel: _dominantFileStatusLabel(statusLabel, nextStatusLabel),
    );
  }
}

class _UnifiedFolderRow extends StatelessWidget {
  final _UnifiedFolderEntry entry;
  final _UnifiedFolderSummary summary;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _UnifiedFolderRow({
    required this.entry,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      minLeadingWidth: 52,
      contentPadding: EdgeInsets.only(left: entry.depth * 20.0),
      leading: SizedBox(
        width: 52,
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              color: Theme.of(context).colorScheme.primary,
            ),
            Icon(
              Icons.folder_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      ),
      onTap: onToggle,
      title: Text(entry.name),
      subtitle: Text('${summary.fileCount} 个文件'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusBadge(label: summary.statusLabel),
          PopupMenuButton<_FileTreeAction>(
            tooltip: '文件夹操作',
            onSelected: (action) {
              switch (action) {
                case _FileTreeAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _FileTreeAction.delete,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.delete_outline),
                  title: Text('删除服务器备份'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UnifiedFileRow extends StatelessWidget {
  final _UnifiedFileEntry entry;
  final String statusLabel;
  final VoidCallback onDelete;

  const _UnifiedFileRow({
    required this.entry,
    required this.statusLabel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final file = entry.file;
    return ListTile(
      dense: true,
      minLeadingWidth: 24,
      contentPadding: EdgeInsets.only(left: entry.depth * 20.0),
      leading: Icon(
        file.decryptable ? _fileIcon(entry.path) : Icons.lock_outline,
      ),
      title: Text(entry.name),
      subtitle: Text(file.subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusBadge(label: statusLabel),
          PopupMenuButton<_FileTreeAction>(
            tooltip: '文件操作',
            onSelected: (action) {
              switch (action) {
                case _FileTreeAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _FileTreeAction.delete,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.delete_outline),
                  title: Text('删除服务器备份'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _FileTreeAction { delete }

class _DeletePolicyNotice extends StatelessWidget {
  final int backedUpCount;

  const _DeletePolicyNotice({required this.backedUpCount});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.35),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_done_outlined, size: 18, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text('删除策略下，$backedUpCount 个文件已完成服务器备份，本地已按策略清理。')),
        ],
      ),
    );
  }
}

class _EmptyFileHint extends StatelessWidget {
  const _EmptyFileHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18),
          SizedBox(width: 8),
          Expanded(child: Text('还没有文件记录，点击顶部扫描按钮生成同步任务。')),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;

  const _StatusBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

class _SyncRootViewData {
  final SyncRoot root;
  final LocalSyncRootMapping? mapping;
  final List<LocalUploadTask> tasks;
  final List<LocalSyncIssue> issues;
  final List<RemoteBackupEntry> remoteBackups;

  const _SyncRootViewData({
    required this.root,
    required this.mapping,
    required this.tasks,
    required this.issues,
    required this.remoteBackups,
  });

  String get displayName {
    if (isMediaBackupRoot) {
      return '相册备份';
    }
    final localPath = mapping?.localPath.trim() ?? '';
    if (localPath.isEmpty) {
      return '未绑定目录 $shortRootId';
    }
    final normalized = localPath.replaceAll('\\', '/');
    final segments = normalized.split('/').where((part) => part.isNotEmpty);
    return segments.isEmpty ? localPath : segments.last;
  }

  String get shortRootId {
    return root.id.length <= 8 ? root.id : root.id.substring(0, 8);
  }

  bool get isUnbound {
    return !isMediaBackupRoot &&
        (mapping == null || mapping!.localPath.trim().isEmpty);
  }

  bool get isMediaBackupRoot {
    return root.encryptedPath.startsWith('media-backup:v1:') ||
        (mapping?.encryptedPath.startsWith('media-backup:v1:') ?? false);
  }

  String get subtitle {
    if (isMediaBackupRoot) {
      return '手机相册照片和视频';
    }
    return isUnbound ? '本机未绑定路径，可在目录操作中重新绑定' : mapping!.localPath;
  }

  int get backedUpDeletedLocalCount {
    return tasks.where((task) => task.status == 'deleted_local').length;
  }

  int get pendingTaskCount {
    return tasks.where((task) => task.status == 'pending').length;
  }

  int get failedTaskCount {
    return tasks.where((task) => task.status == 'failed').length;
  }

  bool get shouldShowDeletePolicyNotice {
    return root.cleanupPolicy == 'delete' && backedUpDeletedLocalCount > 0;
  }

  List<_UnifiedFileRecord> get fileEntries {
    final records = <String, _UnifiedFileRecord>{};
    for (final task in tasks) {
      final path = _normalizeRelativePath(task.relativePath);
      records[path] = (records[path] ?? _UnifiedFileRecord(path: path))
          .copyWith(task: task);
    }
    for (final backup in remoteBackups) {
      final path = _normalizeRelativePath(backup.relativePath);
      records[path] = (records[path] ?? _UnifiedFileRecord(path: path))
          .copyWith(backup: backup);
    }
    final files = records.values.toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  String fileStatusLabel(_UnifiedFileRecord file) {
    final backup = file.backup;
    final task = file.task;
    if (backup != null && !backup.decryptable) {
      return '无法解密';
    }
    if (task?.status == 'pending') {
      return '待上传';
    }
    if (task?.status == 'failed') {
      return '上传失败';
    }
    if (task?.status == 'cleanup_pending') {
      return '待清理';
    }
    if (task?.status == 'cleanup_ignored') {
      return '服务器已备份，本地保留';
    }
    if (task?.status == 'deleted_local' && backup != null) {
      return '服务器已备份，本地已删除';
    }
    if (task?.status == 'deleted_local') {
      return '服务器已备份，本地已删除';
    }
    if (backup == null && task?.status == 'uploaded') {
      return '已上传，服务器待确认';
    }
    if (mapping == null || mapping!.localPath.isEmpty) {
      return backup == null
          ? _taskStatusLabel(task?.status ?? '')
          : '服务器已备份，本机未下载';
    }
    if (backup != null) {
      return '服务器已备份';
    }
    return _taskStatusLabel(task?.status ?? '');
  }

  String get statusLabel {
    if (issues.isNotEmpty) {
      return '待处理';
    }
    if (tasks.any((task) => task.status == 'failed')) {
      return '上传失败';
    }
    if (tasks.any((task) => task.status == 'pending')) {
      return '待上传';
    }
    if (tasks.any((task) => task.status == 'cleanup_pending')) {
      return '待清理';
    }
    if (tasks.isEmpty) {
      return '未扫描';
    }
    if (backedUpDeletedLocalCount == tasks.length) {
      return '已备份';
    }
    if (backedUpDeletedLocalCount > 0) {
      return '部分已备份';
    }
    return '已同步';
  }
}

class _UnifiedFileRecord {
  final String path;
  final LocalUploadTask? task;
  final RemoteBackupEntry? backup;

  const _UnifiedFileRecord({required this.path, this.task, this.backup});

  _UnifiedFileRecord copyWith({
    LocalUploadTask? task,
    RemoteBackupEntry? backup,
  }) {
    return _UnifiedFileRecord(
      path: path,
      task: task ?? this.task,
      backup: backup ?? this.backup,
    );
  }

  bool get decryptable {
    return backup?.decryptable ?? true;
  }

  String get subtitle {
    final size = backup?.sizeBytes ?? task?.sizeBytes;
    final updatedAt = backup?.updatedAt;
    final modifiedAt = task?.modifiedAt;
    final parts = <String>[path];
    if (size != null) {
      parts.add(_formatBytes(size));
    }
    if (updatedAt != null && updatedAt.isNotEmpty) {
      parts.add(updatedAt);
    } else if (modifiedAt != null) {
      parts.add(_formatDateTime(modifiedAt));
    }
    final error = task?.lastError.trim() ?? '';
    if (task?.status == 'failed' && error.isNotEmpty) {
      parts.add(error);
    }
    return parts.join(' · ');
  }
}

String _cleanupPolicyLabel(String policy) {
  return switch (policy) {
    'keep' => '保留本地',
    'delete' => '上传后删除',
    'archive' => '上传后归档',
    _ => policy,
  };
}

String _syncIssueTypeLabel(String type) {
  return switch (type) {
    'download_conflict' => '下载冲突',
    'remote_delete_blocked' => '远端删除被保护',
    _ => '同步问题',
  };
}

String _taskStatusLabel(String status) {
  return switch (status) {
    'pending' => '待上传',
    'failed' => '上传失败',
    'uploaded' => '已上传',
    'clean' => '已同步',
    'deleted_local' => '服务器已备份，本地已删除',
    'archived' => '已归档',
    'cleanup_pending' => '待清理',
    'cleanup_ignored' => '服务器已备份，本地保留',
    _ => status,
  };
}

IconData _historyIcon(String type) {
  return switch (type) {
    'scan' => Icons.search,
    'upload' => Icons.cloud_upload_outlined,
    'pull' => Icons.cloud_download_outlined,
    'cleanup' => Icons.cleaning_services_outlined,
    'delete' => Icons.delete_outline,
    'issue' => Icons.report_problem_outlined,
    'auto_sync' => Icons.schedule_outlined,
    'sync_root' => Icons.folder_outlined,
    'retry' => Icons.refresh,
    _ => Icons.history,
  };
}

Color _historyColor(ColorScheme colorScheme, String result) {
  return switch (result) {
    'success' => colorScheme.primary,
    'failed' => colorScheme.error,
    _ => colorScheme.secondary,
  };
}

String _historyResultLabel(String result) {
  return switch (result) {
    'success' => '成功',
    'failed' => '失败',
    'info' => '记录',
    _ => '记录',
  };
}

String _shortId(String value) {
  return value.length <= 8 ? value : value.substring(0, 8);
}

String _dominantFileStatusLabel(String current, String next) {
  final currentPriority = _fileStatusPriority(current);
  final nextPriority = _fileStatusPriority(next);
  return nextPriority > currentPriority ? next : current;
}

int _fileStatusPriority(String status) {
  return switch (status) {
    '无法解密' => 80,
    '上传失败' => 75,
    '待上传' => 70,
    '待清理' => 60,
    '已上传，服务器待确认' => 50,
    '服务器已备份，本地已删除' => 40,
    '本地已删除' => 35,
    '服务器已备份，本机未下载' => 30,
    '服务器已备份' => 20,
    '已同步' => 10,
    _ => 10,
  };
}

String _folderStatusLabel(String fileStatusLabel) {
  return switch (fileStatusLabel) {
    '无法解密' => '无法解密',
    '上传失败' => '上传失败',
    '待上传' => '待上传',
    '待清理' => '待清理',
    '已上传，服务器待确认' => '待确认',
    '服务器已备份，本地已删除' => '已备份',
    '本地已删除' => '已清理',
    '服务器已备份，本机未下载' => '已备份',
    '服务器已备份' => '已备份',
    _ => fileStatusLabel,
  };
}

IconData _fileIcon(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp')) {
    return Icons.image_outlined;
  }
  if (lower.endsWith('.mp4') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.avi') ||
      lower.endsWith('.mkv')) {
    return Icons.movie_outlined;
  }
  if (lower.endsWith('.pdf')) {
    return Icons.picture_as_pdf_outlined;
  }
  if (lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.gz')) {
    return Icons.archive_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

List<String> _pathParts(String path) {
  return _normalizeRelativePath(
    path,
  ).split('/').where((part) => part.isNotEmpty).toList(growable: false);
}

String _normalizeRelativePath(String path) {
  return path.replaceAll('\\', '/');
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  }
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String _autoSyncSummary(AutoSyncStatus status, {required bool enabled}) {
  if (!enabled) {
    return '自动同步未启用';
  }
  final finishedAt = status.lastFinishedAt;
  if (finishedAt == null) {
    return '自动同步已启用，等待首次执行';
  }
  final result = status.status == 'failed' ? '失败' : '完成';
  final parts = <String>[
    '自动同步$result：${_formatDateTime(finishedAt)}',
    if (status.lastSuccessAt != null)
      '最近成功 ${_formatDateTime(status.lastSuccessAt!)}',
    if (status.scannedCount > 0) '扫描 ${status.scannedCount}',
    if (status.uploadedCount > 0) '上传 ${status.uploadedCount}',
    if (status.failedCount > 0) '失败 ${status.failedCount}',
    if (status.downloadedCount > 0) '下载 ${status.downloadedCount}',
    if (status.remoteDeleteCount > 0) '远端删除 ${status.remoteDeleteCount}',
    if (status.blockedDeleteCount > 0) '保护 ${status.blockedDeleteCount}',
    if (status.message.trim().isNotEmpty) status.message.trim(),
  ];
  return parts.join(' · ');
}

class _CreateSyncRootDialog extends StatefulWidget {
  final FolderPicker folderPicker;
  final FileAccessPermissionGateway fileAccessPermission;
  final LocalPathProtector pathProtector;
  final bool showAndroidFileAccessGuide;

  const _CreateSyncRootDialog({
    required this.folderPicker,
    required this.fileAccessPermission,
    required this.pathProtector,
    required this.showAndroidFileAccessGuide,
  });

  @override
  State<_CreateSyncRootDialog> createState() => _CreateSyncRootDialogState();
}

class _CreateSyncRootDialogState extends State<_CreateSyncRootDialog> {
  static const _androidDownloadsPath = '/storage/emulated/0/Download';

  final _formKey = GlobalKey<FormState>();
  final _localPathController = TextEditingController();
  final _encryptedPathController = TextEditingController();
  String _cleanupPolicy = 'keep';
  String? _folderErrorMessage;
  String? _permissionStatusMessage;

  bool get _isDownloadsPathSelected =>
      _localPathController.text.trim() == _androidDownloadsPath;

  bool get _isCustomPathSelected =>
      _localPathController.text.trim().isNotEmpty && !_isDownloadsPathSelected;

  @override
  void dispose() {
    _localPathController.dispose();
    _encryptedPathController.dispose();
    super.dispose();
  }

  Future<void> _chooseFolder() async {
    String? localPath;
    try {
      localPath = await widget.folderPicker.chooseSyncFolder();
    } on PlatformException catch (error) {
      setState(() {
        _folderErrorMessage = error.message ?? '无法打开目录选择器';
      });
      return;
    } catch (error) {
      setState(() {
        _folderErrorMessage = userReadableErrorMessage(error);
      });
      return;
    }
    if (localPath == null || localPath.trim().isEmpty) {
      return;
    }
    final selectedPath = localPath;
    _setSelectedLocalPath(selectedPath);
  }

  void _setSelectedLocalPath(String selectedPath) {
    setState(() {
      _folderErrorMessage = null;
      _permissionStatusMessage = null;
      _localPathController.text = selectedPath;
      _encryptedPathController.text = widget.pathProtector.protectLocalPath(
        selectedPath,
      );
    });
  }

  void _useAndroidDownloadsPath() {
    _setSelectedLocalPath(_androidDownloadsPath);
    setState(() {
      _permissionStatusMessage = '已使用系统下载目录路径。请确认已授予文件访问权限，否则扫描时可能无法读取该目录。';
    });
  }

  Future<void> _openFileAccessSettings() async {
    try {
      await widget.fileAccessPermission.openFileAccessSettings();
      if (!mounted) {
        return;
      }
      setState(() {
        _folderErrorMessage = null;
        _permissionStatusMessage = '已打开系统授权页。授权完成后请返回 VaultSync，并再次选择本地目录。';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _permissionStatusMessage = null;
        _folderErrorMessage = userReadableErrorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新增同步目录'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showAndroidFileAccessGuide)
                _buildAndroidLocalPathOptions(context)
              else
                _buildDesktopLocalPathPicker(),
              if (_folderErrorMessage != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _folderErrorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              if (_permissionStatusMessage != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _permissionStatusMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('sync_root_encrypted_path_field'),
                controller: _encryptedPathController,
                decoration: const InputDecoration(labelText: '加密路径'),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入加密路径';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey('sync_root_cleanup_policy_field'),
                initialValue: _cleanupPolicy,
                decoration: const InputDecoration(labelText: '清理策略'),
                items: const [
                  DropdownMenuItem(value: 'keep', child: Text('保留本地文件')),
                  DropdownMenuItem(value: 'delete', child: Text('上传后删除本地文件')),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _cleanupPolicy = value;
                  });
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('save_sync_root_button'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildDesktopLocalPathPicker() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            key: const ValueKey('sync_root_local_path_field'),
            controller: _localPathController,
            readOnly: true,
            decoration: const InputDecoration(labelText: '本地目录'),
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(
            key: const ValueKey('choose_sync_folder_button'),
            onPressed: _chooseFolder,
            child: const Text('选择'),
          ),
        ),
      ],
    );
  }

  Widget _buildAndroidLocalPathOptions(BuildContext context) {
    final groupValue = _isDownloadsPathSelected
        ? _androidDownloadsPath
        : _isCustomPathSelected
        ? 'custom'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text('本地路径', style: Theme.of(context).textTheme.titleSmall),
        ),
        const SizedBox(height: 8),
        RadioListTile<String>(
          key: const ValueKey('use_downloads_path_button'),
          value: _androidDownloadsPath,
          groupValue: groupValue,
          onChanged: (_) => _useAndroidDownloadsPath(),
          contentPadding: EdgeInsets.zero,
          title: const Text('同步“下载”文件夹'),
          subtitle: const Text('路径：内部存储/Download'),
        ),
        RadioListTile<String>(
          value: 'custom',
          groupValue: groupValue,
          onChanged: (_) => _chooseFolder(),
          contentPadding: EdgeInsets.zero,
          title: const Text('同步指定文件夹'),
          subtitle: const Text('选择手机上的普通文件夹，“下载”根目录和特定系统文件夹除外'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('choose_sync_folder_button'),
            onPressed: _chooseFolder,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('选择指定文件夹'),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('open_file_access_settings_button'),
            onPressed: _openFileAccessSettings,
            icon: const Icon(Icons.folder_special_outlined),
            label: const Text('授权文件访问权限'),
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('sync_root_local_path_field'),
          controller: _localPathController,
          readOnly: true,
          decoration: const InputDecoration(labelText: '已选择路径'),
        ),
      ],
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.of(context).pop(
      _SyncRootDraft(
        localPath: _localPathController.text.trim(),
        encryptedPath: _encryptedPathController.text.trim(),
        cleanupPolicy: _cleanupPolicy,
        archivePath: '',
      ),
    );
  }
}

sealed class _ManagedSyncRootAction {
  const _ManagedSyncRootAction();
}

class _UpdateSyncRootPolicyAction extends _ManagedSyncRootAction {
  final String cleanupPolicy;

  const _UpdateSyncRootPolicyAction(this.cleanupPolicy);
}

class _DeleteSyncRootAction extends _ManagedSyncRootAction {
  final bool deleteRemote;

  const _DeleteSyncRootAction({required this.deleteRemote});
}

class _ManageSyncRootDialog extends StatefulWidget {
  final _SyncRootViewData rootView;

  const _ManageSyncRootDialog({required this.rootView});

  @override
  State<_ManageSyncRootDialog> createState() => _ManageSyncRootDialogState();
}

class _ManageSyncRootDialogState extends State<_ManageSyncRootDialog> {
  late String _cleanupPolicy = widget.rootView.root.cleanupPolicy == 'delete'
      ? 'delete'
      : 'keep';

  @override
  Widget build(BuildContext context) {
    final mapping = widget.rootView.mapping;
    return AlertDialog(
      title: const Text('管理同步目录'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.rootView.displayName),
          if (mapping != null && mapping.localPath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(mapping.localPath),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('manage_sync_root_cleanup_policy_field'),
            initialValue: _cleanupPolicy,
            decoration: const InputDecoration(labelText: '清理策略'),
            items: const [
              DropdownMenuItem(value: 'keep', child: Text('保留本地文件')),
              DropdownMenuItem(value: 'delete', child: Text('上传后删除本地文件')),
            ],
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                _cleanupPolicy = value;
              });
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('delete_managed_sync_root_button'),
          onPressed: () async {
            final deleteRemote = await showDialog<bool>(
              context: context,
              builder: (context) => const _DeleteSyncRootDialog(),
            );
            if (deleteRemote == null || !context.mounted) {
              return;
            }
            Navigator.of(
              context,
            ).pop(_DeleteSyncRootAction(deleteRemote: deleteRemote));
          },
          child: const Text('删除同步目录'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('save_managed_sync_root_button'),
          onPressed: () => Navigator.of(
            context,
          ).pop(_UpdateSyncRootPolicyAction(_cleanupPolicy)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _DeleteSyncRootDialog extends StatefulWidget {
  const _DeleteSyncRootDialog();

  @override
  State<_DeleteSyncRootDialog> createState() => _DeleteSyncRootDialogState();
}

class _DeleteSyncRootDialogState extends State<_DeleteSyncRootDialog> {
  var _keepRemoteContent = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('删除同步目录'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            key: const ValueKey('keep_remote_content_checkbox'),
            value: _keepRemoteContent,
            onChanged: (value) {
              setState(() {
                _keepRemoteContent = value ?? true;
              });
            },
            title: const Text('保留服务器上的内容'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          Text(
            _keepRemoteContent
                ? '只会从本机取消同步，不会删除 NAS 上已经上传的文件。'
                : '服务器上的该同步目录内容也会被删除，此操作不可恢复。',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm_delete_sync_root_button'),
          onPressed: () => Navigator.of(context).pop(!_keepRemoteContent),
          child: const Text('删除同步目录'),
        ),
      ],
    );
  }
}

class _SyncRootDraft {
  final String localPath;
  final String encryptedPath;
  final String cleanupPolicy;
  final String archivePath;

  const _SyncRootDraft({
    required this.localPath,
    required this.encryptedPath,
    required this.cleanupPolicy,
    required this.archivePath,
  });
}
