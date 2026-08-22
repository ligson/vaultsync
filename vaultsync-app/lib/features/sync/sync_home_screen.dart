import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/device/device_profile.dart';
import '../../core/network/api_exception.dart';
import '../../core/storage/app_storage.dart';
import '../download/remote_file_download.dart';
import '../media_backup/media_backup_models.dart';
import '../media_backup/media_backup_screen.dart';
import '../media_backup/media_backup_gateway.dart';
import '../media_backup/media_backup_scanner.dart';
import '../preview/file_preview_screen.dart';
import '../preview/remote_file_preview.dart';
import '../preview/remote_file_thumbnail.dart';
import 'android_sync_keep_alive.dart';
import 'file_access_permission.dart';
import 'folder_picker.dart';
import 'local_cleanup_executor.dart';
import 'local_path_protector.dart';
import 'local_sync_issue_resolver.dart';
import 'local_sync_monitor.dart';
import 'local_sync_scanner.dart';
import 'local_upload_executor.dart';
import 'local_upload_planner.dart';
import 'remote_metadata_decrypter.dart';
import 'search_center_screen.dart';
import 'sync_models.dart';
import 'sync_pull_executor.dart';
import 'sync_service.dart';
import 'wechat_folder_discovery.dart';

const _androidDownloadsPath = '/storage/emulated/0/Download';
// 微信私有媒体的可用性仍不足以支撑稳定的用户承诺，暂时只保留历史数据兼容。
const _wechatBackupFeatureEnabled = false;

bool _isWechatBackupSource(String sourceType) {
  return sourceType == 'wechat' || sourceType == 'wechat_archive';
}

enum _HomeAction { mediaBackup, wechatBackup, history, scan, upload, pull }

class _HomeActionLabel extends StatelessWidget {
  final IconData icon;
  final String label;

  const _HomeActionLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    );
  }
}

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
  final WechatFolderDiscoveryGateway wechatFolderDiscovery;
  final LocalPathProtector pathProtector;
  final LocalSyncScanGateway? localScanner;
  final LocalUploadExecutionGateway? uploadExecutor;
  final UploadProgressChannel? uploadProgress;
  final DownloadProgressChannel? downloadProgress;
  final RemoteSyncPullGateway? remotePullExecutor;
  final RemoteBackupGateway? remoteBackups;
  final RemoteObjectDeleteGateway? remoteObjectDeletes;
  final RemoteMetadataDecrypter? remoteMetadataDecrypter;
  final RemoteFilePreviewGateway? remoteFilePreviews;
  final RemoteFileDownloadGateway? remoteFileDownloads;
  final RemoteFileThumbnailGateway? remoteFileThumbnails;
  final RemoteFileSaveGateway remoteFileSaver;
  final bool autoSyncEnabled;
  final Duration autoSyncInterval;
  final Duration autoSyncInitialDelay;
  final MediaBackupSourceStore? mediaBackupSources;
  final MediaBackupGateway? mediaGateway;
  final MediaAssetThumbnailGateway? mediaThumbnails;
  final String? devicePlatform;
  final String? currentDeviceDisplayName;
  final String? serverAddress;
  final Future<void> Function()? onConfigureServer;
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
    this.wechatFolderDiscovery = const LocalWechatFolderDiscovery(),
    this.pathProtector = const Sha256LocalPathProtector(),
    this.localScanner,
    this.uploadExecutor,
    this.uploadProgress,
    this.downloadProgress,
    this.remotePullExecutor,
    this.remoteBackups,
    this.remoteObjectDeletes,
    this.remoteMetadataDecrypter,
    this.remoteFilePreviews,
    this.remoteFileDownloads,
    this.remoteFileThumbnails,
    this.remoteFileSaver = const PlatformRemoteFileSaveGateway(),
    this.autoSyncEnabled = false,
    this.autoSyncInterval = const Duration(minutes: 5),
    this.autoSyncInitialDelay = const Duration(seconds: 2),
    this.mediaBackupSources,
    this.mediaGateway,
    this.mediaThumbnails,
    this.devicePlatform,
    this.currentDeviceDisplayName,
    this.serverAddress,
    this.onConfigureServer,
    this.onSignOut,
  });

  @override
  State<SyncHomeScreen> createState() => _SyncHomeScreenState();
}

class _SyncHomeScreenState extends State<SyncHomeScreen>
    with WidgetsBindingObserver {
  static const _androidSyncKeepAlive = AndroidSyncKeepAlive();
  static const _slowServerThreshold = Duration(milliseconds: 1200);
  static const _remoteBackupLoadConcurrency = 3;
  late Future<_SyncHomeData> _homeFuture;
  _SyncHomeData? _cachedHomeData;
  String _selectedDeviceFilterId = _DeviceFilterOption.currentId;
  Timer? _initialAutoSyncTimer;
  Timer? _autoSyncTimer;
  Timer? _slowServerTimer;
  LocalSyncMonitor? _localSyncMonitor;
  final Set<String> _pendingMonitorRootIds = {};
  final Set<String> _activeScanRootIds = {};
  final Set<String> _activeUploadRootIds = {};
  final Set<String> _activeFileDownloadIds = {};
  var _autoSyncRequestedWhileRunning = false;
  var _isScanning = false;
  var _isUploading = false;
  var _isPulling = false;
  var _isAutoSyncing = false;
  var _isAutoCleaningMedia = false;
  var _isSyncStatusOpen = false;
  var _hasReconciledUploadProgress = false;
  var _loadGeneration = 0;
  var _showSlowServerNotice = false;
  SearchIndexEntry? _searchFocus;
  late AppLifecycleState _appLifecycleState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _homeFuture = _loadAndCacheHomeData(bootstrapLocal: true);
    _startAutoSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      unawaited(_autoCleanupUploadedMedia());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _initialAutoSyncTimer?.cancel();
    _autoSyncTimer?.cancel();
    _slowServerTimer?.cancel();
    unawaited(_localSyncMonitor?.stop());
    unawaited(_androidSyncKeepAlive.stop(_devicePlatform));
    super.dispose();
  }

  void _startAutoSync() {
    if (!widget.autoSyncEnabled) {
      return;
    }
    _initialAutoSyncTimer = Timer(
      widget.autoSyncInitialDelay,
      () => _runAutoSync(scanAndUpload: false, resumeUploads: true),
    );
    _autoSyncTimer = Timer.periodic(
      widget.autoSyncInterval,
      (_) => _runAutoSync(scanAndUpload: true),
    );
    _startLocalSyncMonitor();
    unawaited(_androidSyncKeepAlive.start(_devicePlatform));
  }

  String get _devicePlatform =>
      widget.devicePlatform ?? DeviceProfile.current().platform;

  Future<void> _startLocalSyncMonitor() async {
    final monitor = LocalSyncMonitor(
      mappings: widget.syncRootMappings,
      onChanged: _onLocalSyncChanged,
    );
    _localSyncMonitor = monitor;
    await monitor.start();
  }

  void _onLocalSyncChanged(Set<String> syncRootIds) {
    _pendingMonitorRootIds.addAll(syncRootIds);
    if (_isAutoSyncing) {
      _autoSyncRequestedWhileRunning = true;
      return;
    }
    final pending = Set<String>.from(_pendingMonitorRootIds);
    _pendingMonitorRootIds.clear();
    unawaited(_runAutoSync(scanAndUpload: true, syncRootIds: pending));
  }

  Future<_SyncHomeData> _loadHomeData() async {
    final token = await widget.storage.loadAuthToken();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    final currentDeviceId = await widget.storage.loadDeviceId();
    final currentDeviceName = widget.storage is CurrentDeviceInfoStore
        ? await (widget.storage as CurrentDeviceInfoStore).loadDeviceName()
        : null;
    final currentDeviceDisplayName =
        widget.currentDeviceDisplayName?.trim().isNotEmpty == true
        ? widget.currentDeviceDisplayName!.trim()
        : currentDeviceName;
    final roots = await widget.syncRoots.listSyncRoots(token: token);
    final mappings = await widget.syncRootMappings.loadSyncRootMappings();
    final uploadTasks = await widget.uploadTasks.loadUploadTasks();
    final autoSyncStatus =
        await widget.autoSyncStatus?.loadAutoSyncStatus() ??
        const AutoSyncStatus();
    final operationStore = widget.storage is SyncOperationStatusStore
        ? widget.storage as SyncOperationStatusStore
        : null;
    final operationStatuses =
        await operationStore?.loadSyncOperationStatuses() ?? const [];
    final prunedState = await _pruneLocalStateForCurrentRoots(
      roots: roots,
      mappings: mappings,
      uploadTasks: uploadTasks,
      currentDeviceId: currentDeviceId ?? '',
    );
    final issues = await widget.syncIssues?.loadSyncIssues() ?? const [];
    return _SyncHomeData(
      roots: roots,
      mappings: prunedState.mappings,
      uploadTasks: prunedState.uploadTasks,
      issues: issues,
      remoteBackupEntries: _remoteEntriesForCurrentRoots(roots),
      autoSyncStatus: autoSyncStatus,
      operationStatuses: operationStatuses,
      currentDeviceId: currentDeviceId ?? '',
      currentDeviceName: currentDeviceDisplayName ?? '',
      remoteContentLoading: _canLoadRemoteBackups && roots.isNotEmpty,
    );
  }

  Future<_SyncHomeData> _loadAndCacheHomeData({
    bool bootstrapLocal = false,
  }) async {
    final generation = ++_loadGeneration;
    _scheduleSlowServerNotice(generation);
    if (bootstrapLocal) {
      try {
        final localData = await _loadLocalHomeData();
        if (generation == _loadGeneration) {
          _cachedHomeData = localData;
          if (mounted) {
            setState(() {});
          }
        }
      } catch (error) {
        debugPrint('VaultSync local home bootstrap failed: $error');
      }
    }

    late final _SyncHomeData data;
    try {
      data = await _loadHomeData();
    } catch (_) {
      if (generation == _loadGeneration && _cachedHomeData != null) {
        _cachedHomeData = _cachedHomeData!.copyWith(
          remoteContentLoading: false,
        );
      }
      _finishBackgroundRefresh(generation);
      rethrow;
    }
    if (generation != _loadGeneration) {
      return data;
    }
    _cachedHomeData = data;
    _reconcileUploadProgressInBackground();
    if (data.remoteContentLoading) {
      unawaited(_loadRemoteBackupsInBackground(data, generation));
    } else {
      _finishBackgroundRefresh(generation);
    }
    return data;
  }

  bool get _canLoadRemoteBackups =>
      widget.remoteBackups != null && widget.remoteMetadataDecrypter != null;

  Future<_SyncHomeData> _loadLocalHomeData() async {
    final currentDeviceId = await widget.storage.loadDeviceId() ?? '';
    final currentDeviceName = widget.storage is CurrentDeviceInfoStore
        ? await (widget.storage as CurrentDeviceInfoStore).loadDeviceName() ??
              ''
        : '';
    final displayName =
        widget.currentDeviceDisplayName?.trim().isNotEmpty == true
        ? widget.currentDeviceDisplayName!.trim()
        : currentDeviceName;
    final mappings = await widget.syncRootMappings.loadSyncRootMappings();
    final uploadTasks = await widget.uploadTasks.loadUploadTasks();
    final issues = await widget.syncIssues?.loadSyncIssues() ?? const [];
    final autoSyncStatus =
        await widget.autoSyncStatus?.loadAutoSyncStatus() ??
        const AutoSyncStatus();
    final operationStatuses =
        await _operationStatusStore?.loadSyncOperationStatuses() ?? const [];
    final roots = [
      for (final mapping in mappings)
        SyncRoot(
          id: mapping.syncRootId,
          userId: '',
          deviceId: currentDeviceId,
          deviceName: displayName,
          encryptedPath: mapping.encryptedPath,
          encryptionEnabled: mapping.encryptionEnabled,
          cleanupPolicy: mapping.cleanupPolicy,
          archivePath: mapping.archivePath,
          createdAt: '',
        ),
    ];
    return _SyncHomeData(
      roots: roots,
      mappings: mappings,
      uploadTasks: uploadTasks,
      issues: issues,
      remoteBackupEntries: _remoteEntriesForCurrentRoots(roots),
      autoSyncStatus: autoSyncStatus,
      operationStatuses: operationStatuses,
      currentDeviceId: currentDeviceId,
      currentDeviceName: displayName,
      isLocalSnapshot: true,
      remoteContentLoading: true,
    );
  }

  Map<String, List<RemoteBackupEntry>> _remoteEntriesForCurrentRoots(
    List<SyncRoot> roots,
  ) {
    final previous = _cachedHomeData?.remoteBackupEntries ?? const {};
    return {
      for (final root in roots)
        if (previous.containsKey(root.id)) root.id: previous[root.id]!,
    };
  }

  void _scheduleSlowServerNotice(int generation) {
    _slowServerTimer?.cancel();
    _showSlowServerNotice = false;
    _slowServerTimer = Timer(_slowServerThreshold, () {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() => _showSlowServerNotice = true);
    });
  }

  void _finishBackgroundRefresh(int generation) {
    if (generation != _loadGeneration) {
      return;
    }
    _slowServerTimer?.cancel();
    _slowServerTimer = null;
    if (mounted && _showSlowServerNotice) {
      setState(() => _showSlowServerNotice = false);
    } else {
      _showSlowServerNotice = false;
    }
  }

  void _reconcileUploadProgressInBackground() {
    final uploadExecutor = widget.uploadExecutor;
    final reconciler = uploadExecutor is UploadSessionProgressReconciler
        ? uploadExecutor as UploadSessionProgressReconciler
        : null;
    if (_hasReconciledUploadProgress || reconciler == null) {
      return;
    }
    _hasReconciledUploadProgress = true;
    unawaited(() async {
      try {
        final changedCount = await reconciler.reconcilePendingUploadProgress();
        if (changedCount <= 0 || !mounted) {
          return;
        }
        final tasks = await widget.uploadTasks.loadUploadTasks();
        if (!mounted || _cachedHomeData == null) {
          return;
        }
        setState(() {
          _cachedHomeData = _cachedHomeData!.copyWith(uploadTasks: tasks);
        });
      } catch (error) {
        debugPrint('VaultSync upload progress reconciliation failed: $error');
      }
    }());
  }

  Future<void> _loadRemoteBackupsInBackground(
    _SyncHomeData baseData,
    int generation,
  ) async {
    final token = await widget.storage.loadAuthToken();
    if (token == null || token.isEmpty) {
      _finishBackgroundRefresh(generation);
      return;
    }
    final entriesByRoot = Map<String, List<RemoteBackupEntry>>.from(
      baseData.remoteBackupEntries,
    );
    final failedRootIds = <String>{};
    for (
      var offset = 0;
      offset < baseData.roots.length;
      offset += _remoteBackupLoadConcurrency
    ) {
      final end = (offset + _remoteBackupLoadConcurrency).clamp(
        0,
        baseData.roots.length,
      );
      final batch = baseData.roots.sublist(offset, end);
      final results = await Future.wait([
        for (final root in batch) _loadRemoteBackupRoot(token, root),
      ]);
      for (var index = 0; index < batch.length; index += 1) {
        final result = results[index];
        if (result != null) {
          entriesByRoot[batch[index].id] = result;
        } else {
          failedRootIds.add(batch[index].id);
        }
      }
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        final currentData = _cachedHomeData ?? baseData;
        _cachedHomeData = currentData.copyWith(
          remoteBackupEntries: Map.unmodifiable(entriesByRoot),
          remoteContentLoading: end < baseData.roots.length,
          remoteContentError: failedRootIds.isEmpty
              ? ''
              : '部分服务器文件加载失败，已保留其他可用内容',
        );
      });
    }
    _finishBackgroundRefresh(generation);
  }

  Future<List<RemoteBackupEntry>?> _loadRemoteBackupRoot(
    String token,
    SyncRoot root,
  ) async {
    try {
      final gateway = widget.remoteBackups!;
      final decrypter = widget.remoteMetadataDecrypter!;
      final entries = <RemoteBackupEntry>[];
      var cursor = 0;
      while (true) {
        final page = await gateway.listRemoteBackupObjects(
          token: token,
          syncRootId: root.id,
          cursor: cursor,
          limit: 500,
        );
        for (final object in page.items) {
          final entry = await decrypter.decrypt(object);
          entries.add(
            entry.withPayloadMetadata(
              encryptedName: object.encryptedName,
              metadataJson: object.metadataJson,
            ),
          );
        }
        if (!page.hasMore || page.items.isEmpty || page.nextCursor <= cursor) {
          break;
        }
        cursor = page.nextCursor;
      }
      return entries;
    } catch (error) {
      debugPrint('VaultSync remote backup load failed [${root.id}]: $error');
      return null;
    }
  }

  SyncOperationStatusStore? get _operationStatusStore {
    final storage = widget.storage;
    return storage is SyncOperationStatusStore
        ? storage as SyncOperationStatusStore
        : null;
  }

  Future<void> _saveOperationStatuses({
    required Set<String> syncRootIds,
    required String operation,
    required String source,
    required String status,
    required DateTime startedAt,
    String message = '',
    int itemCount = 0,
  }) async {
    final store = _operationStatusStore;
    if (store == null) {
      return;
    }
    final finishedAt = status == 'running' ? null : DateTime.now().toUtc();
    for (final syncRootId in syncRootIds) {
      await store.saveSyncOperationStatus(
        LocalSyncOperationStatus(
          syncRootId: syncRootId,
          operation: operation,
          source: source,
          status: status,
          message: message,
          itemCount: itemCount,
          startedAt: startedAt,
          finishedAt: finishedAt,
        ),
      );
    }
  }

  void _showBusyMessage(String operation) {
    if (!mounted) {
      return;
    }
    final label = operation == 'scan' ? '扫描' : '上传';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已有目录正在$label，请等待当前任务完成')));
  }

  Future<_PrunedLocalSyncState> _pruneLocalStateForCurrentRoots({
    required List<SyncRoot> roots,
    required List<LocalSyncRootMapping> mappings,
    required List<LocalUploadTask> uploadTasks,
    required String currentDeviceId,
  }) async {
    final rootIds = {for (final root in roots) root.id};
    final rootsById = {for (final root in roots) root.id: root};
    var prunedMappings = _syncMappingsWithRemoteRoots(
      mappings: [
        for (final mapping in mappings)
          if (rootIds.contains(mapping.syncRootId)) mapping,
      ],
      rootsById: rootsById,
    );
    final restoredMappings = _restoreKnownCurrentDeviceMappings(
      roots: roots,
      mappings: prunedMappings,
      currentDeviceId: currentDeviceId,
    );
    if (restoredMappings.isNotEmpty) {
      prunedMappings = [...prunedMappings, ...restoredMappings];
    }
    final prunedTasks = _syncUploadTasksWithRemoteRoots(
      tasks: [
        for (final task in uploadTasks)
          if (rootIds.contains(task.syncRootId) &&
              !isIgnoredLocalSyncRelativePath(task.relativePath))
            task,
      ],
      rootsById: rootsById,
    );
    if (!_sameSyncRootMappings(prunedMappings, mappings)) {
      await widget.syncRootMappings.saveSyncRootMappings(prunedMappings);
    }
    if (!_sameUploadTasks(prunedTasks, uploadTasks)) {
      await widget.uploadTasks.saveUploadTasks(prunedTasks);
    }
    return _PrunedLocalSyncState(
      mappings: prunedMappings,
      uploadTasks: prunedTasks,
    );
  }

  List<LocalSyncRootMapping> _syncMappingsWithRemoteRoots({
    required List<LocalSyncRootMapping> mappings,
    required Map<String, SyncRoot> rootsById,
  }) {
    return [
      for (final mapping in mappings)
        _syncMappingWithRemoteRoot(mapping, rootsById),
    ];
  }

  LocalSyncRootMapping _syncMappingWithRemoteRoot(
    LocalSyncRootMapping mapping,
    Map<String, SyncRoot> rootsById,
  ) {
    final root = rootsById[mapping.syncRootId];
    if (root == null) {
      return mapping;
    }
    final cleanupPolicy = _isWechatBackupSource(mapping.sourceType)
        ? 'keep'
        : root.cleanupPolicy;
    if (mapping.encryptedPath == root.encryptedPath &&
        mapping.encryptionEnabled == root.encryptionEnabled &&
        mapping.cleanupPolicy == cleanupPolicy &&
        mapping.archivePath == root.archivePath) {
      return mapping;
    }
    return LocalSyncRootMapping(
      syncRootId: mapping.syncRootId,
      localPath: mapping.localPath,
      encryptedPath: root.encryptedPath,
      encryptionEnabled: root.encryptionEnabled,
      cleanupPolicy: cleanupPolicy,
      archivePath: root.archivePath,
      sourceType: mapping.sourceType,
      includedFileTypes: mapping.includedFileTypes,
    );
  }

  List<LocalUploadTask> _syncUploadTasksWithRemoteRoots({
    required List<LocalUploadTask> tasks,
    required Map<String, SyncRoot> rootsById,
  }) {
    return [
      for (final task in tasks) _syncUploadTaskWithRemoteRoot(task, rootsById),
    ];
  }

  LocalUploadTask _syncUploadTaskWithRemoteRoot(
    LocalUploadTask task,
    Map<String, SyncRoot> rootsById,
  ) {
    final root = rootsById[task.syncRootId];
    if (root == null || task.encryptionEnabled == root.encryptionEnabled) {
      return task;
    }
    return _copyUploadTask(
      task,
      uploadSessionId: '',
      uploadPayloadHash: '',
      uploadTotalSize: 0,
      uploadChunkSize: 0,
      uploadedBytes: 0,
      encryptionEnabled: root.encryptionEnabled,
    );
  }

  List<LocalSyncRootMapping> _restoreKnownCurrentDeviceMappings({
    required List<SyncRoot> roots,
    required List<LocalSyncRootMapping> mappings,
    required String currentDeviceId,
  }) {
    if (currentDeviceId.isEmpty) {
      return const [];
    }
    final mappedRootIds = {for (final mapping in mappings) mapping.syncRootId};
    final restored = <LocalSyncRootMapping>[];
    final platform = widget.devicePlatform ?? DeviceProfile.current().platform;
    for (final root in roots) {
      if (root.deviceId != currentDeviceId || mappedRootIds.contains(root.id)) {
        continue;
      }
      final restoredPath = _restorableLocalPathFor(root, platform);
      if (restoredPath == null) {
        continue;
      }
      restored.add(
        LocalSyncRootMapping(
          syncRootId: root.id,
          localPath: restoredPath,
          encryptedPath: root.encryptedPath,
          encryptionEnabled: root.encryptionEnabled,
          cleanupPolicy: root.cleanupPolicy,
          archivePath: root.archivePath,
          sourceType: root.encryptedPath.startsWith('wechat-backup:v1:archive:')
              ? 'wechat_archive'
              : root.encryptedPath.startsWith('wechat-backup:v1:')
              ? 'wechat'
              : 'folder',
        ),
      );
      mappedRootIds.add(root.id);
    }
    return restored;
  }

  String? _restorableLocalPathFor(SyncRoot root, String platform) {
    if (_isMediaBackupEncryptedPath(root.encryptedPath)) {
      return '';
    }
    if (platform == 'android' &&
        root.encryptedPath ==
            widget.pathProtector.protectLocalPath(_androidDownloadsPath)) {
      return _androidDownloadsPath;
    }
    return null;
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
    if (_isSyncStatusOpen) {
      return;
    }
    setState(() {
      _homeFuture = _loadAndCacheHomeData();
    });
    unawaited(_localSyncMonitor?.refresh());
  }

  Future<void> _signOut() async {
    await widget.onSignOut?.call();
    if (!mounted) {
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _openCreateSyncRootDialog({bool wechatOnly = false}) async {
    if (wechatOnly && !_wechatBackupFeatureEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('微信备份功能暂时下架，已有备份仍会保留。')));
      }
      return;
    }
    final existingWechat = wechatOnly
        ? await _currentDeviceSpecialRoot(
            (root) => root.encryptedPath.startsWith('wechat-backup:v1:'),
          )
        : null;
    final existingMapping = existingWechat == null
        ? null
        : (await widget.syncRootMappings.loadSyncRootMappings())
              .where((mapping) => mapping.syncRootId == existingWechat.id)
              .firstOrNull;
    if (!mounted) {
      return;
    }
    final draft = await showDialog<_SyncRootDraft>(
      context: context,
      builder: (context) => _CreateSyncRootDialog(
        folderPicker: widget.folderPicker,
        fileAccessPermission: widget.fileAccessPermission,
        wechatFolderDiscovery: widget.wechatFolderDiscovery,
        pathProtector: widget.pathProtector,
        devicePlatform:
            widget.devicePlatform ?? DeviceProfile.current().platform,
        showAndroidFileAccessGuide:
            (widget.devicePlatform ?? DeviceProfile.current().platform) ==
            'android',
        wechatOnly: wechatOnly,
        existingMapping: existingMapping,
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
      if (existingWechat != null) {
        await widget.syncRootMappings.saveSyncRootMapping(
          LocalSyncRootMapping(
            syncRootId: existingWechat.id,
            localPath: draft.localPath,
            encryptedPath: existingWechat.encryptedPath,
            encryptionEnabled: existingWechat.encryptionEnabled,
            cleanupPolicy: 'keep',
            archivePath: existingWechat.archivePath,
            sourceType: draft.sourceType,
            includedFileTypes: draft.includedFileTypes,
          ),
        );
        await _addHistory(
          type: 'sync_root',
          result: 'success',
          title: '更新微信文件备份',
          message: '已更新微信文件备份目录 ${draft.localPath}',
          syncRootId: existingWechat.id,
        );
        if (!mounted) {
          return;
        }
        _reloadSyncRoots();
        return;
      }
      final root = await widget.syncRoots.createSyncRoot(
        token: token,
        deviceId: deviceId,
        encryptedPath: _isWechatBackupSource(draft.sourceType)
            ? 'wechat-backup:v1:${draft.sourceType == 'wechat_archive' ? 'archive' : 'files'}-${DateTime.now().microsecondsSinceEpoch}'
            : draft.encryptedPath,
        encryptionEnabled: draft.encryptionEnabled,
        cleanupPolicy: draft.cleanupPolicy,
        archivePath: draft.archivePath,
      );
      await widget.syncRootMappings.saveSyncRootMapping(
        LocalSyncRootMapping(
          syncRootId: root.id,
          localPath: draft.localPath,
          encryptedPath: root.encryptedPath,
          encryptionEnabled: root.encryptionEnabled,
          cleanupPolicy: root.cleanupPolicy,
          archivePath: root.archivePath,
          sourceType: draft.sourceType,
          includedFileTypes: draft.includedFileTypes,
        ),
      );
      await _addHistory(
        type: 'sync_root',
        result: 'success',
        title: _isWechatBackupSource(draft.sourceType) ? '新增微信电脑备份' : '新增同步目录',
        message: _isWechatBackupSource(draft.sourceType)
            ? '已添加微信电脑备份目录 ${draft.localPath}'
            : '已添加同步目录 ${draft.localPath}',
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
      _showBusyMessage('scan');
      return;
    }
    Set<String> actionSyncRootIds = const {};
    final startedAt = DateTime.now().toUtc();
    setState(() {
      _isScanning = true;
    });
    try {
      actionSyncRootIds = await _resolveCurrentDeviceActionSyncRootIds(
        syncRootId: syncRootId,
      );
      if (actionSyncRootIds.any(_activeScanRootIds.contains)) {
        _showBusyMessage('scan');
        return;
      }
      _activeScanRootIds.addAll(actionSyncRootIds);
      await _saveOperationStatuses(
        syncRootIds: actionSyncRootIds,
        operation: 'scan',
        source: 'manual',
        status: 'running',
        startedAt: startedAt,
        message: '正在扫描本地目录',
      );
      await _ensureAndroidFileAccessPermission(
        syncRootId,
        allowedSyncRootIds: actionSyncRootIds,
        openSettingsOnDenied: true,
      );
      await _ensureAndroidSharedMediaDirectoryPermission(
        syncRootId,
        allowedSyncRootIds: actionSyncRootIds,
      );
      await _validateLocalMappingsForScan(actionSyncRootIds);
      final scanner =
          widget.localScanner ??
          LocalSyncScanner(mappings: widget.syncRootMappings);
      final files = await _scanMappedRootsForSyncRootIds(
        scanner: scanner,
        syncRootIds: actionSyncRootIds,
      );
      final planner = LocalUploadPlanner(uploadTasks: widget.uploadTasks);
      final tasks = await planner.enqueueScannedFiles(files);
      final mediaResult = await _scanMediaBackupSources(
        syncRootId: syncRootId,
        allowedSyncRootIds: actionSyncRootIds,
        includeDisabled: true,
      );
      final scannedCount = files.length + mediaResult.scannedCount;
      final createdTaskCount = tasks.length + mediaResult.createdTaskCount;
      final waitingStableCount = tasks
          .where((task) => task.status == 'waiting_stable')
          .length;
      await _saveOperationStatuses(
        syncRootIds: actionSyncRootIds,
        operation: 'scan',
        source: 'manual',
        status: 'success',
        startedAt: startedAt,
        itemCount: scannedCount,
        message: '扫描完成，发现 $scannedCount 个文件',
      );
      await _addHistory(
        type: 'scan',
        result: 'success',
        title: syncRootId == null ? '扫描全部同步目录' : '扫描单个同步目录',
        message:
            '发现 $scannedCount 个本地文件，记录 $createdTaskCount 个同步任务，其中 $waitingStableCount 个等待写入完成',
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
            '扫描$scope发现 $scannedCount 个本地文件，$waitingStableCount 个正在等待写入完成',
          ),
        ),
      );
    } catch (error) {
      await _saveOperationStatuses(
        syncRootIds: actionSyncRootIds,
        operation: 'scan',
        source: 'manual',
        status: 'failed',
        startedAt: startedAt,
        message: userReadableErrorMessage(error),
      );
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
      _activeScanRootIds.removeAll(actionSyncRootIds);
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<void> _executePendingUploads({String? syncRootId}) async {
    final executor = widget.uploadExecutor;
    if (executor == null) {
      return;
    }
    if (_isUploading) {
      _showBusyMessage('upload');
      return;
    }
    Set<String> actionSyncRootIds = const {};
    final startedAt = DateTime.now().toUtc();
    setState(() {
      _isUploading = true;
    });
    try {
      await _homeFuture;
      actionSyncRootIds = await _resolveCurrentDeviceActionSyncRootIds(
        syncRootId: syncRootId,
      );
      if (actionSyncRootIds.any(_activeUploadRootIds.contains)) {
        _showBusyMessage('upload');
        return;
      }
      _activeUploadRootIds.addAll(actionSyncRootIds);
      unawaited(_androidSyncKeepAlive.start(_devicePlatform));
      unawaited(_androidSyncKeepAlive.setTransferActive(_devicePlatform, true));
      await _saveOperationStatuses(
        syncRootIds: actionSyncRootIds,
        operation: 'upload',
        source: 'manual',
        status: 'running',
        startedAt: startedAt,
        message: '正在上传待处理任务',
      );
      final result = syncRootId == null
          ? await _executeCurrentDevicePendingUploads(executor)
          : await executor.executePendingUploads(syncRootId: syncRootId);
      await _saveOperationStatuses(
        syncRootIds: actionSyncRootIds,
        operation: 'upload',
        source: 'manual',
        status: result.failedCount > 0 ? 'failed' : 'success',
        startedAt: startedAt,
        itemCount: result.uploadedCount,
        message:
            '上传 ${result.uploadedCount} 个，移除本地不存在任务 ${result.removedCount} 个，失败 ${result.failedCount} 个',
      );
      await _addHistory(
        type: 'upload',
        result: result.failedCount > 0 ? 'failed' : 'success',
        title: syncRootId == null ? '上传待处理任务' : '上传单个同步目录',
        message:
            '已上传 ${result.uploadedCount} 个任务，移除本地不存在任务 ${result.removedCount} 个，失败 ${result.failedCount} 个',
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
      final removedSuffix = result.removedCount > 0
          ? '，已移除 ${result.removedCount} 个本地不存在任务'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已上传$scope ${result.uploadedCount} 个任务$removedSuffix$failedSuffix',
          ),
        ),
      );
    } catch (error) {
      debugPrint('VaultSync manual upload failed: $error');
      await _saveOperationStatuses(
        syncRootIds: actionSyncRootIds,
        operation: 'upload',
        source: 'manual',
        status: 'failed',
        startedAt: startedAt,
        message: userReadableErrorMessage(error),
      );
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
      _activeUploadRootIds.removeAll(actionSyncRootIds);
      unawaited(
        _androidSyncKeepAlive.setTransferActive(_devicePlatform, false),
      );
      if (!widget.autoSyncEnabled) {
        unawaited(_androidSyncKeepAlive.stop(_devicePlatform));
      }
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
        await _autoCleanupUploadedMedia();
      }
    }
  }

  Future<UploadExecutionResult> _executeCurrentDevicePendingUploads(
    LocalUploadExecutionGateway executor,
  ) async {
    final token = await widget.storage.loadAuthToken();
    final currentDeviceId = await widget.storage.loadDeviceId();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    if (currentDeviceId == null || currentDeviceId.isEmpty) {
      throw Exception('设备状态已失效');
    }
    final roots = await widget.syncRoots.listSyncRoots(token: token);
    var uploadedCount = 0;
    var failedCount = 0;
    var removedCount = 0;
    for (final root in roots) {
      if (root.deviceId != currentDeviceId) {
        continue;
      }
      final result = await executor.executePendingUploads(syncRootId: root.id);
      uploadedCount += result.uploadedCount;
      failedCount += result.failedCount;
      removedCount += result.removedCount;
    }
    return UploadExecutionResult(
      uploadedCount: uploadedCount,
      failedCount: failedCount,
      removedCount: removedCount,
    );
  }

  Future<Set<String>> _resolveCurrentDeviceActionSyncRootIds({
    String? syncRootId,
  }) async {
    final token = await widget.storage.loadAuthToken();
    final currentDeviceId = await widget.storage.loadDeviceId();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    if (currentDeviceId == null || currentDeviceId.isEmpty) {
      throw Exception('设备状态已失效');
    }
    final roots = await widget.syncRoots.listSyncRoots(token: token);
    final currentDeviceRoots = roots
        .where((root) => root.deviceId == currentDeviceId)
        .toList();
    final currentDeviceRootIds = _canonicalSyncRootIds(currentDeviceRoots);
    if (syncRootId != null && !currentDeviceRootIds.contains(syncRootId)) {
      final isCurrentDeviceDuplicate = currentDeviceRoots.any(
        (root) => root.id == syncRootId,
      );
      throw Exception(
        isCurrentDeviceDuplicate
            ? '这是历史重复备份配置，已停止继续扫描。请使用当前设备的主备份配置。'
            : '该同步目录属于其他设备，只能查看，不能在当前设备执行同步',
      );
    }
    return syncRootId == null ? currentDeviceRootIds : {syncRootId};
  }

  Set<String> _canonicalSyncRootIds(List<SyncRoot> roots) {
    final sorted = [...roots]
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    String? mediaRootId;
    String? wechatRootId;
    final result = <String>{};
    for (final root in sorted) {
      if (_isMediaBackupEncryptedPath(root.encryptedPath)) {
        mediaRootId ??= root.id;
        continue;
      }
      if (root.encryptedPath.startsWith('wechat-backup:v1:')) {
        wechatRootId ??= root.id;
        continue;
      }
      result.add(root.id);
    }
    if (mediaRootId != null) {
      result.add(mediaRootId);
    }
    if (wechatRootId != null) {
      result.add(wechatRootId);
    }
    return result;
  }

  Future<List<LocalSyncFile>> _scanMappedRootsForSyncRootIds({
    required LocalSyncScanGateway scanner,
    required Set<String> syncRootIds,
  }) async {
    final files = <LocalSyncFile>[];
    for (final syncRootId in syncRootIds) {
      files.addAll(await scanner.scanMappedRoots(syncRootId: syncRootId));
    }
    return files;
  }

  /// A remote root can survive an app reinstall while its local path mapping
  /// is intentionally kept only on the client. Do not report a successful
  /// zero-file scan when a WeChat mapping is missing or no longer readable.
  Future<void> _validateLocalMappingsForScan(Set<String> syncRootIds) async {
    if (syncRootIds.isEmpty) {
      return;
    }
    final token = await widget.storage.loadAuthToken();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    final roots = await widget.syncRoots.listSyncRoots(token: token);
    final mappings = await widget.syncRootMappings.loadSyncRootMappings();
    final mappingsById = {
      for (final mapping in mappings) mapping.syncRootId: mapping,
    };
    final missingWechat = <String>[];
    for (final root in roots) {
      if (!syncRootIds.contains(root.id) ||
          _isMediaBackupEncryptedPath(root.encryptedPath)) {
        continue;
      }
      final mapping = mappingsById[root.id];
      final localPath = mapping?.localPath.trim() ?? '';
      if (localPath.isEmpty) {
        if (root.encryptedPath.startsWith('wechat-backup:v1:')) {
          missingWechat.add(root.id);
        }
        continue;
      }
      if (root.encryptedPath.startsWith('wechat-backup:v1:') &&
          !await Directory(localPath).exists()) {
        throw Exception(
          _wechatBackupFeatureEnabled
              ? '无法访问微信目录：$localPath。请重新选择目录并授予 VaultSync 访问权限'
              : '无法访问历史微信目录：$localPath。微信备份功能已下架，已有服务器备份仍会保留。',
        );
      }
    }
    if (missingWechat.isNotEmpty) {
      throw Exception(
        _wechatBackupFeatureEnabled
            ? '微信目录尚未绑定。请点击“更多”→“微信文件备份”，自动查找或选择微信目录后保存'
            : '历史微信目录未绑定。微信备份功能已下架，已有服务器备份仍会保留。',
      );
    }
  }

  Future<void> _ensureAndroidSharedMediaDirectoryPermission(
    String? syncRootId, {
    Set<String>? allowedSyncRootIds,
  }) async {
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
      if (allowedSyncRootIds != null &&
          !allowedSyncRootIds.contains(mapping.syncRootId)) {
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

  Future<void> _ensureAndroidFileAccessPermission(
    String? syncRootId, {
    Set<String>? allowedSyncRootIds,
    bool openSettingsOnDenied = false,
  }) async {
    final platform = widget.devicePlatform ?? DeviceProfile.current().platform;
    if (platform != 'android') {
      return;
    }
    final mappings = await widget.syncRootMappings.loadSyncRootMappings();
    final needsFileAccess = mappings.any((mapping) {
      if (syncRootId != null && mapping.syncRootId != syncRootId) {
        return false;
      }
      if (allowedSyncRootIds != null &&
          !allowedSyncRootIds.contains(mapping.syncRootId)) {
        return false;
      }
      if (_isMediaBackupEncryptedPath(mapping.encryptedPath)) {
        return false;
      }
      return _isWechatBackupSource(mapping.sourceType) ||
          _isAndroidDownloadsPath(mapping.localPath);
    });
    if (!needsFileAccess) {
      return;
    }
    if (await widget.fileAccessPermission.hasFileAccessPermission()) {
      return;
    }
    if (openSettingsOnDenied) {
      await widget.fileAccessPermission.openFileAccessSettings();
    }
    throw Exception('未获得所有文件访问权限，无法扫描“下载”文件夹。请在系统授权页允许 VaultSync 访问所有文件后返回重试。');
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

  Future<LocalCleanupResult?> _autoCleanupUploadedMedia() async {
    if (!mounted ||
        _isAutoCleaningMedia ||
        _isUploading ||
        _appLifecycleState != AppLifecycleState.resumed ||
        !_isMobilePlatform ||
        widget.mediaGateway == null) {
      return null;
    }
    final tasks = await widget.uploadTasks.loadUploadTasks();
    final hasUploadedMedia = tasks.any(
      (task) => task.sourceType == 'media_asset' && task.status == 'uploaded',
    );
    if (!hasUploadedMedia || !mounted) {
      return null;
    }

    _isAutoCleaningMedia = true;
    try {
      final cleaner = LocalCleanupExecutor(
        mappings: widget.syncRootMappings,
        uploadTasks: widget.uploadTasks,
        mediaCleaner: widget.mediaGateway,
      );
      final result = await cleaner.cleanupNewlyUploadedMediaTasks();
      await _addHistory(
        type: 'cleanup',
        result: result.pendingCount > 0 ? 'failed' : 'success',
        title: '自动清理已备份相册资源',
        message: '已自动清理 ${result.cleanedCount} 个，仍待处理 ${result.pendingCount} 个',
      );
      if (mounted) {
        _reloadSyncRoots();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.pendingCount > 0
                  ? '已清理 ${result.cleanedCount} 个，${result.pendingCount} 个需稍后批量确认'
                  : '已自动清理 ${result.cleanedCount} 个已备份相册资源',
            ),
          ),
        );
      }
      return result;
    } finally {
      _isAutoCleaningMedia = false;
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

  Future<bool> _openMediaCleanupConfirmationPage() async {
    try {
      final data = await _loadHomeData();
      if (!mounted) {
        return false;
      }
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (context) => _MediaCleanupConfirmationPage(
            data: data,
            onConfirmCleanup: _confirmMediaCleanupTaskIds,
            onIgnoreOne: _ignoreCleanupTask,
          ),
        ),
      );
      if (!mounted) {
        return changed == true;
      }
      if (changed == true) {
        _reloadSyncRoots();
      }
      return changed == true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      _showErrorSnackBar(error);
      return false;
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
            '下载 ${result.downloadedCount} 个更新，无需下载 ${result.skippedDownloadCount} 个，处理 ${result.deleteCount} 个删除，保护 ${result.blockedDeleteCount} 个本地改动',
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
            '已下载 ${result.downloadedCount} 个远端更新，无需下载 ${result.skippedDownloadCount} 个，处理 ${result.deleteCount} 个删除$blockedSuffix',
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

  Future<void> _runAutoSync({
    required bool scanAndUpload,
    bool resumeUploads = false,
    Set<String>? syncRootIds,
  }) async {
    if (!mounted) {
      return;
    }
    if (_isAutoSyncing) {
      if (scanAndUpload) {
        _autoSyncRequestedWhileRunning = true;
        if (syncRootIds != null) {
          _pendingMonitorRootIds.addAll(syncRootIds);
        }
      }
      return;
    }
    final statusStore = widget.autoSyncStatus;
    final startedAt = DateTime.now().toUtc();
    var scannedCount = 0;
    var uploadedCount = 0;
    var failedCount = 0;
    var removedUploadTaskCount = 0;
    var downloadedCount = 0;
    var remoteDeleteCount = 0;
    var blockedDeleteCount = 0;
    var autoScanRootIds = <String>{};
    var autoUploadRootIds = <String>{};
    String? currentStage;
    _localSyncMonitor?.pause();
    setState(() {
      _isAutoSyncing = true;
    });
    try {
      await _homeFuture;
      if (scanAndUpload && !_isScanning) {
        setState(() {
          _isScanning = true;
        });
        currentStage = '扫描本地目录';
        final actionSyncRootIds =
            await _resolveCurrentDeviceActionSyncRootIds();
        final requestedRootIds = syncRootIds;
        final scanRootIds = requestedRootIds == null
            ? actionSyncRootIds
            : actionSyncRootIds.intersection(requestedRootIds);
        autoScanRootIds = scanRootIds.difference(_activeScanRootIds);
        _activeScanRootIds.addAll(autoScanRootIds);
        await _saveOperationStatuses(
          syncRootIds: autoScanRootIds,
          operation: 'scan',
          source: 'auto',
          status: 'running',
          startedAt: startedAt,
          message: '自动扫描正在运行',
        );
        await _ensureAndroidFileAccessPermission(
          null,
          allowedSyncRootIds: autoScanRootIds,
        );
        final scanner =
            widget.localScanner ??
            LocalSyncScanner(mappings: widget.syncRootMappings);
        final files = await _scanMappedRootsForSyncRootIds(
          scanner: scanner,
          syncRootIds: autoScanRootIds,
        );
        scannedCount = files.length;
        final planner = LocalUploadPlanner(uploadTasks: widget.uploadTasks);
        await planner.enqueueScannedFiles(files);
        currentStage = '扫描相册备份';
        final mediaResult = await _scanMediaBackupSources(
          allowedSyncRootIds: autoScanRootIds,
        );
        scannedCount += mediaResult.scannedCount;
        await _saveOperationStatuses(
          syncRootIds: autoScanRootIds,
          operation: 'scan',
          source: 'auto',
          status: 'success',
          startedAt: startedAt,
          itemCount: scannedCount,
          message: '自动扫描完成，发现 $scannedCount 个文件',
        );
        _activeScanRootIds.removeAll(autoScanRootIds);
        if (mounted) {
          setState(() {
            _isScanning = false;
          });
        }
      }

      final uploadExecutor = widget.uploadExecutor;
      if ((scanAndUpload || resumeUploads) &&
          uploadExecutor != null &&
          !_isUploading) {
        setState(() {
          _isUploading = true;
        });
        currentStage = '上传待处理任务';
        autoUploadRootIds = (await _resolveCurrentDeviceActionSyncRootIds())
            .difference(_activeUploadRootIds);
        _activeUploadRootIds.addAll(autoUploadRootIds);
        await _saveOperationStatuses(
          syncRootIds: autoUploadRootIds,
          operation: 'upload',
          source: 'auto',
          status: 'running',
          startedAt: startedAt,
          message: '自动上传正在运行',
        );
        unawaited(
          _androidSyncKeepAlive.setTransferActive(_devicePlatform, true),
        );
        late final UploadExecutionResult result;
        try {
          result = await _executeCurrentDevicePendingUploads(uploadExecutor);
        } finally {
          unawaited(
            _androidSyncKeepAlive.setTransferActive(_devicePlatform, false),
          );
        }
        uploadedCount = result.uploadedCount;
        failedCount = result.failedCount;
        removedUploadTaskCount = result.removedCount;
        await _saveOperationStatuses(
          syncRootIds: autoUploadRootIds,
          operation: 'upload',
          source: 'auto',
          status: result.failedCount > 0 ? 'failed' : 'success',
          startedAt: startedAt,
          itemCount: uploadedCount,
          message:
              '自动上传 $uploadedCount 个，移除本地不存在任务 $removedUploadTaskCount 个，失败 $failedCount 个',
        );
        _activeUploadRootIds.removeAll(autoUploadRootIds);
        if (mounted) {
          setState(() {
            _isUploading = false;
          });
          await _autoCleanupUploadedMedia();
        }
      }

      final pullExecutor = widget.remotePullExecutor;
      if (pullExecutor != null && !_isPulling) {
        setState(() {
          _isPulling = true;
        });
        currentStage = '拉取服务器变更';
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
      currentStage = null;

      await statusStore?.saveAutoSyncStatus(
        AutoSyncStatus(
          lastStartedAt: startedAt,
          lastFinishedAt: DateTime.now().toUtc(),
          lastSuccessAt: DateTime.now().toUtc(),
          status: 'success',
          message: scanAndUpload
              ? '自动同步完成'
              : resumeUploads
              ? '启动后续传与拉取完成'
              : '启动后自动拉取完成',
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
        title: scanAndUpload
            ? '自动同步完成'
            : resumeUploads
            ? '启动后续传与拉取完成'
            : '启动后自动拉取完成',
        message:
            '扫描 $scannedCount 个，上传 $uploadedCount 个，移除本地不存在任务 $removedUploadTaskCount 个，失败 $failedCount 个，下载 $downloadedCount 个，删除 $remoteDeleteCount 个',
      );
    } catch (error, stackTrace) {
      debugPrint('VaultSync auto sync failed [$currentStage]: $error');
      debugPrintStack(stackTrace: stackTrace);
      final message = _syncStageErrorMessage(currentStage, error);
      await _saveOperationStatuses(
        syncRootIds: _activeScanRootIds.intersection(autoScanRootIds),
        operation: 'scan',
        source: 'auto',
        status: 'failed',
        startedAt: startedAt,
        message: message,
      );
      await _saveOperationStatuses(
        syncRootIds: _activeUploadRootIds.intersection(autoUploadRootIds),
        operation: 'upload',
        source: 'auto',
        status: 'failed',
        startedAt: startedAt,
        message: message,
      );
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
        title: scanAndUpload
            ? '自动同步失败'
            : resumeUploads
            ? '启动后续传与拉取失败'
            : '启动后自动拉取失败',
        message: message,
      );
    } finally {
      _activeScanRootIds.removeAll(autoScanRootIds);
      _activeUploadRootIds.removeAll(autoUploadRootIds);
      _localSyncMonitor?.resume();
      if (mounted) {
        setState(() {
          _isScanning = false;
          _isUploading = false;
          _isPulling = false;
          _isAutoSyncing = false;
          _homeFuture = _loadAndCacheHomeData();
        });
      }
      if (_autoSyncRequestedWhileRunning && mounted) {
        _autoSyncRequestedWhileRunning = false;
        final pending = Set<String>.from(_pendingMonitorRootIds);
        _pendingMonitorRootIds.clear();
        if (pending.isNotEmpty) {
          unawaited(_runAutoSync(scanAndUpload: true, syncRootIds: pending));
        }
      }
    }
  }

  Future<MediaBackupScanResult> _scanMediaBackupSources({
    String? syncRootId,
    Set<String>? allowedSyncRootIds,
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
      if (allowedSyncRootIds != null &&
          !allowedSyncRootIds.contains(source.syncRootId)) {
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

  String _syncStageErrorMessage(String? stage, Object error) {
    final message = userReadableErrorMessage(error);
    if (stage == null || stage.isEmpty) {
      return message;
    }
    return '$stage失败：$message';
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
            encryptionEnabled: mapping.encryptionEnabled,
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
      _isSyncStatusOpen = true;
      late final bool? changed;
      try {
        changed = await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(
            builder: (context) => _SyncStatusPage(
              initialData: initialData,
              loadData: _loadHomeData,
              retryFailedUploads: _retryFailedUploads,
              retryCleanupPending: _retryCleanupPending,
              retryCleanupTask: _retryCleanupTask,
              ignoreCleanupTask: _ignoreCleanupTask,
              openMediaCleanupConfirmationPage:
                  _openMediaCleanupConfirmationPage,
              enqueueConflictIssue: _enqueueConflictIssue,
              enqueueConflictIssues: _enqueueConflictIssues,
              resolveIssue: _markIssueResolved,
              retryEnabled: widget.uploadExecutor != null,
              autoSyncEnabled: widget.autoSyncEnabled,
              uploadProgress: widget.uploadProgress,
              downloadProgress: widget.downloadProgress,
            ),
          ),
        );
      } finally {
        _isSyncStatusOpen = false;
      }
      if (!mounted) {
        return;
      }
      if (changed == true) {
        _reloadSyncRoots();
      }
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

  Future<SyncRoot?> _currentDeviceSpecialRoot(
    bool Function(SyncRoot root) matches,
  ) async {
    final token = await widget.storage.loadAuthToken();
    final deviceId = await widget.storage.loadDeviceId();
    if (token == null ||
        token.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty) {
      return null;
    }
    final roots = await widget.syncRoots.listSyncRoots(token: token);
    final candidates =
        roots
            .where((root) => root.deviceId == deviceId && matches(root))
            .toList()
          ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return candidates.firstOrNull;
  }

  Future<void> _openMediaBackupScreen() async {
    final existingRoot = await _currentDeviceSpecialRoot(
      (root) => _isMediaBackupEncryptedPath(root.encryptedPath),
    );
    LocalMediaBackupSource? existingSource;
    final mediaSources = _mediaBackupSourcesStore;
    if (existingRoot != null && mediaSources != null) {
      existingSource = (await mediaSources.loadMediaBackupSources())
          .where((source) => source.syncRootId == existingRoot.id)
          .firstOrNull;
      existingSource ??= (await _fallbackMediaBackupSources(
        const [],
      )).where((source) => source.syncRootId == existingRoot.id).firstOrNull;
    }
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaBackupScreen(
          onSave: _saveMediaBackupDraft,
          initialDraft: existingSource == null
              ? null
              : MediaBackupDraft(
                  mediaTypes: existingSource.mediaTypes,
                  cleanupPolicy: existingSource.cleanupPolicy,
                  encryptionEnabled: existingRoot!.encryptionEnabled,
                  wifiOnly: existingSource.wifiOnly,
                  autoBackupEnabled: existingSource.autoBackupEnabled,
                ),
          encryptionLocked: existingRoot != null,
        ),
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
    final existingRoot = await _currentDeviceSpecialRoot(
      (root) => _isMediaBackupEncryptedPath(root.encryptedPath),
    );
    final sources = await mediaSources.loadMediaBackupSources();
    final now = DateTime.now().toUtc();
    if (existingRoot != null) {
      final existingSource = sources
          .where((source) => source.syncRootId == existingRoot.id)
          .firstOrNull;
      final sourceId =
          existingSource?.id ??
          _mediaBackupSourceId(existingRoot.encryptedPath);
      final updated = LocalMediaBackupSource(
        id: sourceId,
        syncRootId: existingRoot.id,
        name: '相册备份',
        mediaTypes: draft.mediaTypes,
        albumScope: existingSource?.albumScope ?? 'all',
        albumIds: existingSource?.albumIds ?? const [],
        cleanupPolicy: draft.cleanupPolicy,
        encryptionEnabled: existingRoot.encryptionEnabled,
        wifiOnly: draft.wifiOnly,
        autoBackupEnabled: draft.autoBackupEnabled,
        createdAt: existingSource?.createdAt ?? now,
        updatedAt: now,
      );
      await mediaSources.saveMediaBackupSources([
        for (final source in sources)
          if (source.syncRootId != existingRoot.id) source,
        updated,
      ]);
      if (existingRoot.cleanupPolicy != draft.cleanupPolicy) {
        await widget.syncRoots.updateSyncRootCleanupPolicy(
          token: token,
          syncRootId: existingRoot.id,
          cleanupPolicy: draft.cleanupPolicy,
        );
      }
      await widget.syncRootMappings.saveSyncRootMapping(
        LocalSyncRootMapping(
          syncRootId: existingRoot.id,
          localPath: '',
          encryptedPath: existingRoot.encryptedPath,
          encryptionEnabled: existingRoot.encryptionEnabled,
          cleanupPolicy: draft.cleanupPolicy,
          archivePath: existingRoot.archivePath,
        ),
      );
      await _addHistory(
        type: 'media_backup',
        result: 'success',
        title: '更新相册备份',
        message: '已更新当前设备的相册备份配置',
        syncRootId: existingRoot.id,
      );
      return;
    }
    final sourceId = 'media-${now.microsecondsSinceEpoch}';
    final root = await widget.syncRoots.createSyncRoot(
      token: token,
      deviceId: deviceId,
      encryptedPath: 'media-backup:v1:$sourceId',
      encryptionEnabled: draft.encryptionEnabled,
      cleanupPolicy: draft.cleanupPolicy,
      archivePath: '',
    );
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
        encryptionEnabled: draft.encryptionEnabled,
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
        encryptionEnabled: root.encryptionEnabled,
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
        title: const Text('同步'),
        actions: [
          IconButton(
            key: const ValueKey('open_search_center_button'),
            tooltip: '搜索',
            onPressed: _openSearchCenter,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            key: const ValueKey('open_sync_status_button'),
            tooltip: '同步状态',
            onPressed: _openSyncStatusPage,
            icon: const Icon(Icons.sync),
          ),
          PopupMenuButton<_HomeAction>(
            key: const ValueKey('sync_more_actions_button'),
            tooltip: '更多操作',
            onSelected: _handleHomeAction,
            itemBuilder: (context) => [
              if (_isMobilePlatform)
                const PopupMenuItem(
                  key: ValueKey('open_media_backup_button'),
                  value: _HomeAction.mediaBackup,
                  child: _HomeActionLabel(
                    icon: Icons.photo_library_outlined,
                    label: '相册备份',
                  ),
                ),
              if (_wechatBackupFeatureEnabled)
                const PopupMenuItem(
                  key: ValueKey('open_wechat_backup_button'),
                  value: _HomeAction.wechatBackup,
                  child: _HomeActionLabel(
                    icon: Icons.chat_bubble_outline,
                    label: '微信文件备份',
                  ),
                ),
              const PopupMenuItem(
                key: ValueKey('open_sync_history_button'),
                value: _HomeAction.history,
                child: _HomeActionLabel(icon: Icons.history, label: '同步记录'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                key: ValueKey('scan_local_files_button'),
                value: _HomeAction.scan,
                child: _HomeActionLabel(icon: Icons.search, label: '扫描本地文件'),
              ),
              PopupMenuItem(
                key: const ValueKey('execute_uploads_button'),
                value: _HomeAction.upload,
                enabled: widget.uploadExecutor != null,
                child: const _HomeActionLabel(
                  icon: Icons.cloud_upload_outlined,
                  label: '上传待处理任务',
                ),
              ),
              PopupMenuItem(
                key: const ValueKey('pull_remote_changes_button'),
                value: _HomeAction.pull,
                enabled: widget.remotePullExecutor != null && !_isPulling,
                child: const _HomeActionLabel(
                  icon: Icons.cloud_download_outlined,
                  label: '拉取远端变更',
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        key: const ValueKey('add_sync_root_button'),
        tooltip: '新增目录',
        onPressed: _openCreateSyncRootDialog,
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<_SyncHomeData>(
        future: _homeFuture,
        builder: (context, snapshot) {
          final cachedData = _cachedHomeData ?? snapshot.data;
          final isRefreshing =
              snapshot.connectionState != ConnectionState.done ||
              (cachedData?.remoteContentLoading ?? false);
          if (isRefreshing && cachedData == null) {
            return const _SyncHomeLoadingSkeleton();
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            final message = userReadableErrorMessage(
              error ?? Exception('加载同步主页失败'),
            );
            if (cachedData != null && cachedData.roots.isNotEmpty) {
              return _buildHomeContent(
                context,
                cachedData,
                isRefreshing: false,
                refreshError: message,
              );
            }
            final canSignOut =
                widget.onSignOut != null ||
                error is ApiException && error.statusCode == 401;
            return _SyncErrorView(
              message: message,
              serverAddress: widget.serverAddress ?? '',
              canSignOut: canSignOut,
              onRetry: _reloadSyncRoots,
              onConfigureServer: widget.onConfigureServer,
              onSignOut: _signOut,
            );
          }
          return _buildHomeContent(
            context,
            cachedData ?? _SyncHomeData(),
            isRefreshing: isRefreshing,
          );
        },
      ),
    );
  }

  void _handleHomeAction(_HomeAction action) {
    switch (action) {
      case _HomeAction.mediaBackup:
        _openMediaBackupScreen();
      case _HomeAction.wechatBackup:
        _openCreateSyncRootDialog(wechatOnly: true);
      case _HomeAction.history:
        _openSyncHistoryPage();
      case _HomeAction.scan:
        _scanLocalFiles();
      case _HomeAction.upload:
        _executePendingUploads();
      case _HomeAction.pull:
        _pullRemoteChanges();
    }
  }

  Future<void> _openSearchCenter() async {
    final data = _cachedHomeData;
    if (data == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('同步目录正在加载，请稍后再搜索')));
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SearchCenterScreen(
          entries: const [],
          loadEntries: () async {
            await Future<void>.delayed(Duration.zero);
            return _buildSearchIndexEntries(data);
          },
          indexComplete: !data.remoteContentLoading,
          onPreview: _previewSearchEntry,
          onDownload: _downloadSearchEntry,
          onDetails: _showSearchEntryDetails,
          onLocate: _locateSearchEntry,
        ),
      ),
    );
  }

  Future<List<SearchIndexEntry>> _buildSearchIndexEntries(
    _SyncHomeData data,
  ) async {
    final entries = <SearchIndexEntry>[];
    var processedFiles = 0;
    for (final rootView in data.rootViews) {
      for (final file in rootView.fileEntries) {
        entries.add(
          SearchIndexEntry(
            rootId: rootView.root.id,
            rootName: rootView.displayName,
            deviceId: rootView.root.deviceId,
            deviceName: rootView.deviceDisplayName,
            isCurrentDevice: rootView.isCurrentDeviceRoot,
            path: file.path,
            sizeBytes: file.backup?.sizeBytes ?? file.task?.sizeBytes,
            updatedAt: _unifiedFileUpdatedAt(file),
            statusLabel: rootView.fileStatusLabel(file),
            canPreview: file.canPreview,
            canDownload: file.canDownload,
          ),
        );
        processedFiles += 1;
        if (processedFiles % 200 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    return entries;
  }

  (_SyncRootViewData, _UnifiedFileRecord)? _resolveSearchEntry(
    SearchIndexEntry entry,
  ) {
    final data = _cachedHomeData;
    if (data == null) {
      return null;
    }
    for (final rootView in data.rootViews) {
      if (rootView.root.id != entry.rootId) {
        continue;
      }
      for (final file in rootView.fileEntries) {
        if (file.path == entry.path) {
          return (rootView, file);
        }
      }
    }
    return null;
  }

  Future<void> _previewSearchEntry(SearchIndexEntry entry) async {
    final resolved = _resolveSearchEntry(entry);
    if (resolved == null) {
      return;
    }
    await _openFilePreview(resolved.$2);
  }

  Future<void> _downloadSearchEntry(SearchIndexEntry entry) async {
    final resolved = _resolveSearchEntry(entry);
    if (resolved == null) {
      return;
    }
    await _downloadRemoteFile(resolved.$2);
  }

  Future<void> _showSearchEntryDetails(SearchIndexEntry entry) async {
    final resolved = _resolveSearchEntry(entry);
    if (resolved == null || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _FilePropertiesDialog(
        file: resolved.$2,
        rootView: resolved.$1,
        statusLabel: resolved.$1.fileStatusLabel(resolved.$2),
      ),
    );
  }

  Future<void> _locateSearchEntry(SearchIndexEntry entry) async {
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
    setState(() {
      _selectedDeviceFilterId = _DeviceFilterOption.allId;
      _searchFocus = entry;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _searchFocus = null);
      }
    });
  }

  Widget _buildHomeContent(
    BuildContext context,
    _SyncHomeData data, {
    required bool isRefreshing,
    String refreshError = '',
  }) {
    final roots = data.roots;
    final allRootViews = data.rootViews;
    final filterOptions = _DeviceFilterOption.fromRootViews(allRootViews);
    final selectedFilterId = _resolveSelectedDeviceFilterId(filterOptions);
    final rootViews = _filterRootViews(allRootViews, selectedFilterId);
    final headerChildren = <Widget>[
      if (_showSlowServerNotice) ...[
        _SlowServerNotice(showingLocalData: data.isLocalSnapshot),
        const SizedBox(height: 10),
      ],
      if (data.remoteContentError.isNotEmpty) ...[
        _InlineSyncWarning(message: data.remoteContentError),
        const SizedBox(height: 10),
      ],
      if (refreshError.isNotEmpty) ...[
        _InlineSyncError(message: refreshError),
        const SizedBox(height: 12),
      ],
      if (filterOptions.length > 1) ...[
        _DeviceFilterBar(
          options: filterOptions,
          selectedId: selectedFilterId,
          onChanged: (nextId) {
            setState(() {
              _selectedDeviceFilterId = nextId;
            });
          },
        ),
        const SizedBox(height: 12),
      ],
      if (rootViews.isEmpty && data.isLocalSnapshot)
        const _WaitingForServerDirectories()
      else if (rootViews.isEmpty)
        Padding(
          padding: EdgeInsets.all(roots.isEmpty ? 48 : 16),
          child: Center(
            child: Text(
              _emptyRootMessage(
                roots: roots,
                refreshError: refreshError,
                selectedFilterId: selectedFilterId,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
    ];
    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  if (index < headerChildren.length) {
                    return headerChildren[index];
                  }
                  final rootView = rootViews[index - headerChildren.length];
                  return RepaintBoundary(
                    child: _buildSyncRootPanel(rootView, rootViews.length),
                  );
                }, childCount: headerChildren.length + rootViews.length),
              ),
            ),
          ],
        ),
        if (isRefreshing)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  Widget _buildSyncRootPanel(_SyncRootViewData rootView, int rootCount) {
    return _SyncRootPanel(
      key: ValueKey('sync_root_panel_${rootView.root.id}'),
      rootView: rootView,
      initiallyExpanded:
          rootCount == 1 || _searchFocus?.rootId == rootView.root.id,
      focusPath: _searchFocus?.rootId == rootView.root.id
          ? _searchFocus?.path
          : null,
      mediaThumbnails: widget.mediaThumbnails,
      remoteFileThumbnails: widget.remoteFileThumbnails,
      fileBrowserPreferences: widget.storage is FileBrowserPreferenceStore
          ? widget.storage as FileBrowserPreferenceStore
          : null,
      onManage: rootView.isCurrentDeviceRoot
          ? () => _openManageSyncRootDialog(rootView)
          : null,
      onScan: rootView.canRunLocalSync
          ? () => _scanLocalFiles(syncRootId: rootView.root.id)
          : null,
      onBind:
          rootView.isCurrentDeviceRoot &&
              (!rootView.isWechatBackupRoot || _wechatBackupFeatureEnabled)
          ? rootView.isWechatBackupRoot
                ? () => _openCreateSyncRootDialog(wechatOnly: true)
                : () => _bindLocalFolder(rootView)
          : null,
      onUpload: widget.uploadExecutor == null || !rootView.canRunLocalSync
          ? null
          : () => _executePendingUploads(syncRootId: rootView.root.id),
      onRetryFailed:
          widget.uploadExecutor == null ||
              rootView.failedTaskCount == 0 ||
              !rootView.isCurrentDeviceRoot
          ? null
          : () => _retryFailedUploads(syncRootId: rootView.root.id),
      onDeleteFile: rootView.isCurrentDeviceRoot
          ? (file) => _deleteRemoteFile(rootView, file)
          : null,
      onDeleteFolder: rootView.isCurrentDeviceRoot
          ? (folderPath) => _deleteRemoteFolder(rootView, folderPath)
          : null,
      onPreviewFile: widget.remoteFilePreviews == null
          ? null
          : (file) => _openFilePreview(file),
      onDownloadFile: widget.remoteFileDownloads == null
          ? null
          : (file) => _downloadRemoteFile(file),
      onShowFileDetails: (file) => _showSearchFileDetails(rootView, file),
      onShowDetails: () => _showSyncRootDetails(rootView),
    );
  }

  Future<void> _showSearchFileDetails(
    _SyncRootViewData rootView,
    _UnifiedFileRecord file,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _FilePropertiesDialog(
        file: file,
        rootView: rootView,
        statusLabel: rootView.fileStatusLabel(file),
      ),
    );
  }

  Future<void> _showSyncRootDetails(_SyncRootViewData rootView) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SyncRootDetailsSheet(rootView: rootView),
    );
  }

  String _resolveSelectedDeviceFilterId(List<_DeviceFilterOption> options) {
    if (options.any((option) => option.id == _selectedDeviceFilterId)) {
      return _selectedDeviceFilterId;
    }
    return _DeviceFilterOption.currentId;
  }

  List<_SyncRootViewData> _filterRootViews(
    List<_SyncRootViewData> rootViews,
    String selectedFilterId,
  ) {
    if (selectedFilterId == _DeviceFilterOption.allId) {
      return rootViews;
    }
    if (selectedFilterId == _DeviceFilterOption.currentId) {
      return [
        for (final rootView in rootViews)
          if (rootView.isCurrentDeviceRoot) rootView,
      ];
    }
    const devicePrefix = _DeviceFilterOption.devicePrefix;
    if (selectedFilterId.startsWith(devicePrefix)) {
      final deviceId = selectedFilterId.substring(devicePrefix.length);
      return [
        for (final rootView in rootViews)
          if (rootView.root.deviceId == deviceId) rootView,
      ];
    }
    return rootViews;
  }

  String _emptyRootMessage({
    required List<SyncRoot> roots,
    required String refreshError,
    required String selectedFilterId,
  }) {
    if (refreshError.isNotEmpty) {
      return '暂无可展示的同步目录';
    }
    if (roots.isEmpty) {
      return '暂无同步目录';
    }
    if (selectedFilterId == _DeviceFilterOption.currentId) {
      return '当前设备暂无同步目录，可切换到“全部设备”查看其他设备目录';
    }
    return '此设备暂无同步目录';
  }

  Future<void> _openFilePreview(_UnifiedFileRecord file) async {
    final backup = file.backup;
    final previews = widget.remoteFilePreviews;
    if (backup == null || previews == null || !file.canPreview) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => FilePreviewScreen(
          fileName: backup.name,
          loader: () async {
            final token = await widget.storage.loadAuthToken();
            if (token == null || token.isEmpty) {
              throw Exception('登录状态已失效，请重新登录');
            }
            return previews.load(token: token, entry: backup);
          },
        ),
      ),
    );
  }

  Future<void> _downloadRemoteFile(_UnifiedFileRecord file) async {
    final backup = file.backup;
    final downloads = widget.remoteFileDownloads;
    if (backup == null || downloads == null || !file.canDownload) {
      return;
    }
    final downloadId = '${backup.syncRootId}:${backup.versionId}';
    if (_activeFileDownloadIds.contains(downloadId)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('此文件正在下载，请等待完成')));
      return;
    }
    var progressDialogOpen = false;
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    try {
      final token = await widget.storage.loadAuthToken();
      if (token == null || token.isEmpty) {
        throw Exception('登录状态已失效，请重新登录');
      }
      final target = await widget.remoteFileSaver.chooseTarget(
        fileName: backup.name,
        platform: _devicePlatform,
      );
      if (target == null || !mounted) {
        return;
      }
      _activeFileDownloadIds.add(downloadId);
      progressDialogOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _FileDownloadProgressDialog(fileName: backup.name),
        ).whenComplete(() {
          progressDialogOpen = false;
        }),
      );
      final data = await downloads.load(token: token, entry: backup);
      await widget.remoteFileSaver.write(target: target, bytes: data.bytes);
      if (progressDialogOpen && rootNavigator.mounted) {
        rootNavigator.pop();
        progressDialogOpen = false;
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('下载完成：${target.displayPath}')));
    } catch (error) {
      if (progressDialogOpen && rootNavigator.mounted) {
        rootNavigator.pop();
        progressDialogOpen = false;
      }
      if (mounted) {
        _showErrorSnackBar(error);
      }
    } finally {
      _activeFileDownloadIds.remove(downloadId);
    }
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
      final result = await _enqueueConflictIssues([issue]);
      if (result.successCount == 0) {
        throw Exception('冲突副本加入上传队列失败');
      }
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

  Future<_BatchIssueActionResult> _enqueueConflictIssues(
    List<LocalSyncIssue> issues,
  ) async {
    final syncIssues = widget.syncIssues;
    if (syncIssues == null) {
      throw Exception('本地问题存储不可用');
    }
    final resolver = LocalSyncIssueResolver(
      mappings: widget.syncRootMappings,
      uploadTasks: widget.uploadTasks,
      syncIssues: syncIssues,
    );
    var successCount = 0;
    var failedCount = 0;
    var firstErrorMessage = '';
    for (final issue in issues) {
      try {
        await resolver.enqueueConflictForUpload(issue);
        successCount += 1;
      } catch (error) {
        if (firstErrorMessage.isEmpty) {
          firstErrorMessage = userReadableErrorMessage(error);
        }
        failedCount += 1;
      }
    }
    return _BatchIssueActionResult(
      successCount: successCount,
      failedCount: failedCount,
      firstErrorMessage: firstErrorMessage,
    );
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
            key: const ValueKey('cancel_remote_delete_button'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm_remote_delete_button'),
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
    // WeChat roots use the dedicated dialog so automatic discovery and the
    // source classification are preserved when a mapping is missing.
    if (_wechatBackupFeatureEnabled &&
        rootView.isWechatBackupRoot &&
        (rootView.mapping == null ||
            rootView.mapping!.localPath.trim().isEmpty)) {
      await _openCreateSyncRootDialog(wechatOnly: true);
      return;
    }
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
      if (rootView.isWechatBackupRoot && cleanupPolicy != 'keep') {
        throw Exception('微信文件备份固定保留本地文件，不能启用上传后删除');
      }
      final retainedCount = rootView.tasks
          .where((task) => task.status == 'clean')
          .length;
      if (cleanupPolicy == 'delete' &&
          rootView.root.cleanupPolicy != 'delete' &&
          retainedCount > 0) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认删除已备份的本地文件'),
            content: Text(
              '该目录已有 $retainedCount 个文件上传后保留在本地。确认后，这些文件也会按新策略进入清理队列；文件内容变化或删除权限不足时不会强行删除。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('暂不处理'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认并清理'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) {
          return;
        }
      }
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
              sourceType: mapping.sourceType,
              includedFileTypes: mapping.includedFileTypes,
            )
          else
            mapping,
      ]);
      if (!mounted) {
        return;
      }
      _reloadSyncRoots();
      if (cleanupPolicy == 'delete' && retainedCount > 0) {
        await _retryCleanupPending();
      }
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
    var remoteDeleted = false;
    final cancellationGateway =
        widget.uploadExecutor is LocalUploadCancellationGateway
        ? widget.uploadExecutor as LocalUploadCancellationGateway
        : null;
    try {
      final token = await widget.storage.loadAuthToken();
      if (token == null || token.isEmpty) {
        throw Exception('登录状态已失效');
      }
      cancellationGateway?.pauseSyncRootUploads(syncRootId);
      await widget.syncRoots.deleteSyncRoot(
        token: token,
        syncRootId: syncRootId,
        deleteRemote: deleteRemote,
      );
      remoteDeleted = true;
      cancellationGateway?.confirmSyncRootDeleted(syncRootId);
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
      if (!remoteDeleted) {
        cancellationGateway?.resumeSyncRootUploads(syncRootId);
      }
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
  bool? encryptionEnabled,
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
    stabilityObservedAt: task.stabilityObservedAt,
    sourceContentHash: task.sourceContentHash,
    lastError: lastError ?? task.lastError,
    uploadSessionId: uploadSessionId ?? task.uploadSessionId,
    uploadPayloadHash: uploadPayloadHash ?? task.uploadPayloadHash,
    uploadTotalSize: uploadTotalSize ?? task.uploadTotalSize,
    uploadChunkSize: uploadChunkSize ?? task.uploadChunkSize,
    uploadedBytes: uploadedBytes ?? task.uploadedBytes,
    sourceType: task.sourceType,
    assetId: task.assetId,
    assetMediaType: task.assetMediaType,
    encryptionEnabled: encryptionEnabled ?? task.encryptionEnabled,
  );
}

bool _sameSyncRootMappings(
  List<LocalSyncRootMapping> left,
  List<LocalSyncRootMapping> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    final a = left[index];
    final b = right[index];
    if (a.syncRootId != b.syncRootId ||
        a.localPath != b.localPath ||
        a.encryptedPath != b.encryptedPath ||
        a.encryptionEnabled != b.encryptionEnabled ||
        a.cleanupPolicy != b.cleanupPolicy ||
        a.archivePath != b.archivePath ||
        a.sourceType != b.sourceType ||
        a.includedFileTypes != b.includedFileTypes) {
      return false;
    }
  }
  return true;
}

bool _sameUploadTasks(List<LocalUploadTask> left, List<LocalUploadTask> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    final a = left[index];
    final b = right[index];
    if (a.id != b.id ||
        a.syncRootId != b.syncRootId ||
        a.localPath != b.localPath ||
        a.relativePath != b.relativePath ||
        a.sizeBytes != b.sizeBytes ||
        !a.modifiedAt.isAtSameMomentAs(b.modifiedAt) ||
        a.status != b.status ||
        a.attempts != b.attempts ||
        !a.createdAt.isAtSameMomentAs(b.createdAt) ||
        a.lastError != b.lastError ||
        a.uploadSessionId != b.uploadSessionId ||
        a.uploadPayloadHash != b.uploadPayloadHash ||
        a.uploadTotalSize != b.uploadTotalSize ||
        a.uploadChunkSize != b.uploadChunkSize ||
        a.uploadedBytes != b.uploadedBytes ||
        a.sourceType != b.sourceType ||
        a.assetId != b.assetId ||
        a.assetMediaType != b.assetMediaType ||
        a.encryptionEnabled != b.encryptionEnabled) {
      return false;
    }
  }
  return true;
}

class _FileDownloadProgressDialog extends StatelessWidget {
  final String fileName;

  const _FileDownloadProgressDialog({required this.fileName});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在下载'),
      content: Row(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              '$fileName\n正在安全下载、解密并保存...',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncHomeData {
  final List<SyncRoot> roots;
  final List<LocalSyncRootMapping> mappings;
  final List<LocalUploadTask> uploadTasks;
  final List<LocalSyncIssue> issues;
  final Map<String, List<RemoteBackupEntry>> remoteBackupEntries;
  final AutoSyncStatus autoSyncStatus;
  final List<LocalSyncOperationStatus> operationStatuses;
  final String currentDeviceId;
  final String currentDeviceName;
  final bool isLocalSnapshot;
  final bool remoteContentLoading;
  final String remoteContentError;

  _SyncHomeData({
    this.roots = const [],
    this.mappings = const [],
    this.uploadTasks = const [],
    this.issues = const [],
    this.remoteBackupEntries = const {},
    this.autoSyncStatus = const AutoSyncStatus(),
    this.operationStatuses = const [],
    this.currentDeviceId = '',
    this.currentDeviceName = '',
    this.isLocalSnapshot = false,
    this.remoteContentLoading = false,
    this.remoteContentError = '',
  });

  _SyncHomeData copyWith({
    List<SyncRoot>? roots,
    List<LocalSyncRootMapping>? mappings,
    List<LocalUploadTask>? uploadTasks,
    List<LocalSyncIssue>? issues,
    Map<String, List<RemoteBackupEntry>>? remoteBackupEntries,
    AutoSyncStatus? autoSyncStatus,
    List<LocalSyncOperationStatus>? operationStatuses,
    String? currentDeviceId,
    String? currentDeviceName,
    bool? isLocalSnapshot,
    bool? remoteContentLoading,
    String? remoteContentError,
  }) {
    return _SyncHomeData(
      roots: roots ?? this.roots,
      mappings: mappings ?? this.mappings,
      uploadTasks: uploadTasks ?? this.uploadTasks,
      issues: issues ?? this.issues,
      remoteBackupEntries: remoteBackupEntries ?? this.remoteBackupEntries,
      autoSyncStatus: autoSyncStatus ?? this.autoSyncStatus,
      operationStatuses: operationStatuses ?? this.operationStatuses,
      currentDeviceId: currentDeviceId ?? this.currentDeviceId,
      currentDeviceName: currentDeviceName ?? this.currentDeviceName,
      isLocalSnapshot: isLocalSnapshot ?? this.isLocalSnapshot,
      remoteContentLoading: remoteContentLoading ?? this.remoteContentLoading,
      remoteContentError: remoteContentError ?? this.remoteContentError,
    );
  }

  late final List<LocalSyncIssue> openIssues = [
    for (final issue in issues)
      if (issue.status == 'open') issue,
  ];

  late final Map<String, LocalSyncRootMapping> _mappingsByRoot = {
    for (final mapping in mappings) mapping.syncRootId: mapping,
  };
  late final Map<String, List<LocalUploadTask>> _tasksByRoot = _groupByRoot(
    uploadTasks,
    (task) => task.syncRootId,
  );
  late final Map<String, List<LocalSyncIssue>> _issuesByRoot = _groupByRoot(
    openIssues,
    (issue) => issue.syncRootId,
  );
  late final Map<String, List<LocalSyncOperationStatus>> _operationsByRoot =
      _groupByRoot(operationStatuses, (operation) => operation.syncRootId);

  static Map<String, List<T>> _groupByRoot<T>(
    Iterable<T> values,
    String Function(T value) rootId,
  ) {
    final grouped = <String, List<T>>{};
    for (final value in values) {
      grouped.putIfAbsent(rootId(value), () => <T>[]).add(value);
    }
    return grouped;
  }

  List<_SyncRootViewData>? _rootViewsCache;

  List<_SyncRootViewData> get rootViews => _rootViewsCache ??= [
    for (final root in roots)
      _SyncRootViewData(
        root: root,
        mapping: _mappingsByRoot[root.id],
        tasks: _tasksByRoot[root.id] ?? const [],
        issues: _issuesByRoot[root.id] ?? const [],
        remoteBackups: remoteBackupEntries[root.id] ?? const [],
        operations: _operationsByRoot[root.id] ?? const [],
        currentDeviceId: currentDeviceId,
        currentDeviceName: currentDeviceName,
      ),
  ];

  int get pendingTaskCount {
    return uploadTasks.where((task) => task.status == 'pending').length;
  }

  int get waitingStableTaskCount {
    return uploadTasks.where((task) => task.status == 'waiting_stable').length;
  }

  int get failedTaskCount {
    return uploadTasks.where((task) => task.status == 'failed').length;
  }

  int get cleanupPendingTaskCount {
    return rootViews.fold(
      0,
      (total, rootView) =>
          total +
          rootView.tasks
              .where(
                (task) =>
                    _taskNeedsLocalCleanup(task, rootView.root.cleanupPolicy),
              )
              .length,
    );
  }

  int get fileCleanupPendingTaskCount {
    return rootViews.fold(
      0,
      (total, rootView) =>
          total +
          rootView.tasks
              .where(
                (task) =>
                    _taskNeedsLocalCleanup(task, rootView.root.cleanupPolicy) &&
                    task.sourceType != 'media_asset',
              )
              .length,
    );
  }

  int get activeTaskCount {
    return pendingTaskCount + waitingStableTaskCount + cleanupPendingTaskCount;
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
  final String serverAddress;
  final bool canSignOut;
  final VoidCallback onRetry;
  final Future<void> Function()? onConfigureServer;
  final Future<void> Function() onSignOut;

  const _SyncErrorView({
    required this.message,
    required this.serverAddress,
    required this.canSignOut,
    required this.onRetry,
    this.onConfigureServer,
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
            if (serverAddress.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '当前后端地址：$serverAddress',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('error_retry_button'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                if (onConfigureServer != null)
                  OutlinedButton.icon(
                    key: const ValueKey('error_server_settings_button'),
                    onPressed: onConfigureServer,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('后端地址'),
                  ),
              ],
            ),
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
  final Future<bool> Function() openMediaCleanupConfirmationPage;
  final Future<void> Function(LocalSyncIssue issue) enqueueConflictIssue;
  final Future<_BatchIssueActionResult> Function(List<LocalSyncIssue> issues)
  enqueueConflictIssues;
  final Future<void> Function(String issueId) resolveIssue;
  final bool retryEnabled;
  final bool autoSyncEnabled;
  final UploadProgressChannel? uploadProgress;
  final DownloadProgressChannel? downloadProgress;

  const _SyncStatusPage({
    required this.initialData,
    required this.loadData,
    required this.retryFailedUploads,
    required this.retryCleanupPending,
    required this.retryCleanupTask,
    required this.ignoreCleanupTask,
    required this.openMediaCleanupConfirmationPage,
    required this.enqueueConflictIssue,
    required this.enqueueConflictIssues,
    required this.resolveIssue,
    required this.retryEnabled,
    required this.autoSyncEnabled,
    this.uploadProgress,
    this.downloadProgress,
  });

  @override
  State<_SyncStatusPage> createState() => _SyncStatusPageState();
}

class _BatchIssueActionResult {
  final int successCount;
  final int failedCount;
  final String firstErrorMessage;

  const _BatchIssueActionResult({
    required this.successCount,
    required this.failedCount,
    this.firstErrorMessage = '',
  });
}

class _SyncStatusPageState extends State<_SyncStatusPage> {
  late _SyncHomeData _data;
  var _isRetrying = false;
  var _isRefreshing = false;
  var _hasChanges = false;
  String _refreshError = '';
  UploadProgressPhase _lastUploadPhase = UploadProgressPhase.idle;
  DownloadProgressPhase _lastDownloadPhase = DownloadProgressPhase.idle;

  @override
  void initState() {
    super.initState();
    _data = widget.initialData;
    _lastUploadPhase =
        widget.uploadProgress?.value.phase ?? UploadProgressPhase.idle;
    _lastDownloadPhase =
        widget.downloadProgress?.value.phase ?? DownloadProgressPhase.idle;
    widget.uploadProgress?.addListener(_handleUploadProgress);
    widget.downloadProgress?.addListener(_handleDownloadProgress);
  }

  @override
  void didUpdateWidget(covariant _SyncStatusPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uploadProgress == widget.uploadProgress &&
        oldWidget.downloadProgress == widget.downloadProgress) {
      return;
    }
    oldWidget.uploadProgress?.removeListener(_handleUploadProgress);
    oldWidget.downloadProgress?.removeListener(_handleDownloadProgress);
    _lastUploadPhase =
        widget.uploadProgress?.value.phase ?? UploadProgressPhase.idle;
    _lastDownloadPhase =
        widget.downloadProgress?.value.phase ?? DownloadProgressPhase.idle;
    widget.uploadProgress?.addListener(_handleUploadProgress);
    widget.downloadProgress?.addListener(_handleDownloadProgress);
  }

  @override
  void dispose() {
    widget.uploadProgress?.removeListener(_handleUploadProgress);
    widget.downloadProgress?.removeListener(_handleDownloadProgress);
    super.dispose();
  }

  void _handleUploadProgress() {
    final nextPhase = widget.uploadProgress?.value.phase;
    if (nextPhase == UploadProgressPhase.completed &&
        _lastUploadPhase != UploadProgressPhase.completed) {
      unawaited(_refresh());
    }
    _lastUploadPhase = nextPhase ?? UploadProgressPhase.idle;
  }

  void _handleDownloadProgress() {
    final nextPhase = widget.downloadProgress?.value.phase;
    if (nextPhase == DownloadProgressPhase.completed &&
        _lastDownloadPhase != DownloadProgressPhase.completed) {
      unawaited(_refresh());
    }
    _lastDownloadPhase = nextPhase ?? DownloadProgressPhase.idle;
  }

  Future<void> _refresh() async {
    if (_isRefreshing) {
      return;
    }
    setState(() {
      _isRefreshing = true;
      _refreshError = '';
    });
    try {
      final nextData = await widget.loadData();
      if (!mounted) {
        return;
      }
      setState(() {
        _data = nextData;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _refreshError = userReadableErrorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
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
      _hasChanges = true;
      if (!mounted) {
        return;
      }
      await _refresh();
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
      _hasChanges = true;
      if (!mounted) {
        return;
      }
      await _refresh();
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
      _hasChanges = true;
      if (!mounted) {
        return;
      }
      await _refresh();
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
      _hasChanges = true;
      if (!mounted) {
        return;
      }
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  Future<void> _openMediaCleanupPage() async {
    final changed = await widget.openMediaCleanupConfirmationPage();
    if (!changed) {
      return;
    }
    _hasChanges = true;
    if (!mounted) {
      return;
    }
    await _refresh();
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
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => _SyncIssueDetailPage(
          issue: issue,
          rootName: rootName,
          onEnqueueConflict: widget.enqueueConflictIssue,
          onResolve: widget.resolveIssue,
        ),
      ),
    );
    if (changed != true) {
      return;
    }
    _hasChanges = true;
    if (!mounted) {
      return;
    }
    await _refresh();
  }

  Future<void> _enqueueAllConflicts(List<LocalSyncIssue> issues) async {
    final conflictIssues = _downloadConflictIssues(issues);
    if (conflictIssues.isEmpty || _isRetrying) {
      return;
    }
    final confirmed = await _confirmBatchIssueAction(
      title: '上传冲突副本',
      message: '将把 ${conflictIssues.length} 个冲突副本加入上传队列。原文件和服务器文件不会被删除。',
      confirmLabel: '加入上传队列',
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() {
      _isRetrying = true;
    });
    var successCount = 0;
    var failedCount = 0;
    try {
      final result = await widget.enqueueConflictIssues(conflictIssues);
      if (result.successCount > 0) {
        _hasChanges = true;
      }
      successCount = result.successCount;
      failedCount = result.failedCount;
      if (!mounted) {
        return;
      }
      final failedReason =
          failedCount > 0 && result.firstErrorMessage.isNotEmpty
          ? '，原因：${result.firstErrorMessage}'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已加入 $successCount 个冲突副本，失败 $failedCount 个$failedReason',
          ),
        ),
      );
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  Future<void> _resolveAllConflicts(List<LocalSyncIssue> issues) async {
    final conflictIssues = _downloadConflictIssues(issues);
    if (conflictIssues.isEmpty || _isRetrying) {
      return;
    }
    final confirmed = await _confirmBatchIssueAction(
      title: '关闭冲突提醒',
      message:
          '将关闭 ${conflictIssues.length} 个冲突提醒。这个操作只关闭提醒，不会删除本地文件、冲突副本或服务器备份。',
      confirmLabel: '关闭提醒',
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() {
      _isRetrying = true;
    });
    var successCount = 0;
    var failedCount = 0;
    try {
      for (final issue in conflictIssues) {
        try {
          await widget.resolveIssue(issue.id);
          successCount += 1;
        } catch (_) {
          failedCount += 1;
        }
      }
      if (successCount > 0) {
        _hasChanges = true;
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已关闭 $successCount 个冲突提醒，失败 $failedCount 个')),
      );
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  List<LocalSyncIssue> _downloadConflictIssues(List<LocalSyncIssue> issues) {
    return [
      for (final issue in issues)
        if (issue.type == 'download_conflict') issue,
    ];
  }

  Future<bool> _confirmBatchIssueAction({
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
            key: const ValueKey('cancel_batch_issue_action_button'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm_batch_issue_action_button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          Navigator.of(context).pop(_hasChanges);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('同步状态'),
          automaticallyImplyLeading: false,
          leading: IconButton(
            key: const ValueKey('close_sync_status_button'),
            tooltip: '返回同步',
            onPressed: () => Navigator.of(context).pop(_hasChanges),
            icon: const Icon(Icons.arrow_back),
          ),
          actions: [
            IconButton(
              key: const ValueKey('refresh_sync_status_button'),
              tooltip: '刷新状态',
              onPressed: _isRefreshing ? null : _refresh,
              icon: _isRefreshing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                if (widget.uploadProgress != null ||
                    widget.downloadProgress != null)
                  _SyncTransferProgressPanel(
                    uploadProgress: widget.uploadProgress,
                    downloadProgress: widget.downloadProgress,
                  ),
                if (_refreshError.isNotEmpty) ...[
                  _InlineSyncError(message: _refreshError),
                  const SizedBox(height: 12),
                ],
                _SyncStatusCenter(
                  data: _data,
                  retryEnabled: widget.retryEnabled && !_isRetrying,
                  onRetryFailed: () => _retryFailed(),
                  onRetryCleanup: _isRetrying ? null : _retryCleanup,
                  autoSyncEnabled: widget.autoSyncEnabled,
                ),
                const SizedBox(height: 12),
                _FailedUploadTaskList(
                  data: _data,
                  retryEnabled: widget.retryEnabled && !_isRetrying,
                  onRetryRoot: (syncRootId) =>
                      _retryFailed(syncRootId: syncRootId),
                ),
                const SizedBox(height: 12),
                _CleanupPendingTaskList(
                  data: _data,
                  onOpenMediaCleanupPage: _openMediaCleanupPage,
                  onRetryCleanup: _isRetrying ? null : _retryCleanup,
                  onRetryOne: _isRetrying ? null : _retryOneCleanup,
                  onIgnoreOne: _isRetrying ? null : _ignoreOneCleanup,
                ),
                const SizedBox(height: 12),
                _OpenSyncIssueList(
                  data: _data,
                  batchEnabled: !_isRetrying,
                  onOpenIssue: (issue) => _openIssueDetail(_data, issue),
                  onEnqueueAllConflicts: () =>
                      _enqueueAllConflicts(_data.openIssues),
                  onResolveAllConflicts: () =>
                      _resolveAllConflicts(_data.openIssues),
                ),
              ],
            ),
            if (_isRefreshing)
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }
}

class _SyncTransferProgressPanel extends StatefulWidget {
  final UploadProgressChannel? uploadProgress;
  final DownloadProgressChannel? downloadProgress;

  const _SyncTransferProgressPanel({
    this.uploadProgress,
    this.downloadProgress,
  });

  @override
  State<_SyncTransferProgressPanel> createState() =>
      _SyncTransferProgressPanelState();
}

class _SyncTransferProgressPanelState
    extends State<_SyncTransferProgressPanel> {
  late bool _showDownload;

  @override
  void initState() {
    super.initState();
    _showDownload = widget.downloadProgress?.value.isActive == true;
    widget.uploadProgress?.addListener(_handleUploadProgress);
    widget.downloadProgress?.addListener(_handleDownloadProgress);
  }

  @override
  void dispose() {
    widget.uploadProgress?.removeListener(_handleUploadProgress);
    widget.downloadProgress?.removeListener(_handleDownloadProgress);
    super.dispose();
  }

  void _handleUploadProgress() {
    if (widget.uploadProgress?.value.phase == UploadProgressPhase.idle) {
      return;
    }
    if (mounted) {
      setState(() {
        _showDownload = false;
      });
    }
  }

  void _handleDownloadProgress() {
    if (widget.downloadProgress?.value.phase == DownloadProgressPhase.idle) {
      return;
    }
    if (mounted) {
      setState(() {
        _showDownload = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showDownload && widget.downloadProgress != null) {
      return _DownloadProgressPanel(progress: widget.downloadProgress!);
    }
    final uploadProgress = widget.uploadProgress;
    if (uploadProgress != null) {
      return _UploadProgressPanel(progress: uploadProgress);
    }
    return const SizedBox.shrink();
  }
}

class _UploadProgressPanel extends StatelessWidget {
  final UploadProgressChannel progress;

  const _UploadProgressPanel({required this.progress});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final value = progress.value;
        if (value.phase == UploadProgressPhase.idle) {
          return const SizedBox.shrink();
        }
        final colorScheme = Theme.of(context).colorScheme;
        final fileName = _uploadProgressFileName(value.currentPath);
        final completedTasks = value.uploadedCount + value.failedCount;
        final remainingTasks = value.taskCount > completedTasks
            ? value.taskCount - completedTasks
            : 0;
        final fileProgress = _uploadFileProgress(value);
        return Container(
          key: const ValueKey('upload_progress_panel'),
          margin: const EdgeInsets.fromLTRB(4, 2, 4, 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _uploadProgressIcon(value.phase),
                    size: 20,
                    color: _uploadProgressColor(colorScheme, value.phase),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _uploadProgressTitle(value),
                      key: const ValueKey('upload_progress_title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              if (fileName.isNotEmpty &&
                  value.phase != UploadProgressPhase.completed) ...[
                const SizedBox(height: 10),
                Text(
                  fileName,
                  key: const ValueKey('upload_progress_file_name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              if (value.phase != UploadProgressPhase.completed) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  key: const ValueKey('upload_file_progress_bar'),
                  value: fileProgress,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 6),
                Text(
                  _uploadProgressDetail(value),
                  key: const ValueKey('upload_progress_detail'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (value.speedBytesPerSecond > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '速度 ${_formatSpeed(value.speedBytesPerSecond)}',
                    key: const ValueKey('upload_speed'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
              if (value.errorMessage.isNotEmpty &&
                  value.phase == UploadProgressPhase.failed) ...[
                const SizedBox(height: 6),
                Text(
                  value.errorMessage,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  Text('已完成 ${value.uploadedCount}'),
                  Text('失败 ${value.failedCount}'),
                  Text('剩余 $remainingTasks'),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DownloadProgressPanel extends StatelessWidget {
  final DownloadProgressChannel progress;

  const _DownloadProgressPanel({required this.progress});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final value = progress.value;
        if (value.phase == DownloadProgressPhase.idle) {
          return const SizedBox.shrink();
        }
        final colorScheme = Theme.of(context).colorScheme;
        final completedTasks =
            value.downloadedCount + value.failedCount + value.skippedCount;
        final remainingTasks = value.taskCount > completedTasks
            ? value.taskCount - completedTasks
            : 0;
        final fileProgress = value.totalBytes <= 0
            ? null
            : (value.downloadedBytes / value.totalBytes).clamp(0.0, 1.0);
        return Container(
          key: const ValueKey('download_progress_panel'),
          margin: const EdgeInsets.fromLTRB(4, 2, 4, 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _downloadProgressIcon(value.phase),
                    size: 20,
                    color: value.phase == DownloadProgressPhase.failed
                        ? colorScheme.error
                        : colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _downloadProgressTitle(value),
                      key: const ValueKey('download_progress_title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              if (value.currentPath.isNotEmpty &&
                  value.phase != DownloadProgressPhase.completed) ...[
                const SizedBox(height: 10),
                Text(
                  _uploadProgressFileName(value.currentPath),
                  key: const ValueKey('download_progress_file_name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (value.phase != DownloadProgressPhase.completed) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  key: const ValueKey('download_file_progress_bar'),
                  value: fileProgress,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 6),
                Text(
                  _downloadProgressDetail(value),
                  key: const ValueKey('download_progress_detail'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (value.errorMessage.isNotEmpty &&
                  value.phase == DownloadProgressPhase.failed)
                Text(
                  value.errorMessage,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
                ),
              if (value.speedBytesPerSecond > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '速度 ${_formatSpeed(value.speedBytesPerSecond)}',
                  key: const ValueKey('download_speed'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  Text('已完成 ${value.downloadedCount}'),
                  Text('无需下载 ${value.skippedCount}'),
                  Text('失败 ${value.failedCount}'),
                  Text('剩余 $remainingTasks'),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

String _downloadProgressTitle(DownloadProgress progress) {
  if (progress.phase == DownloadProgressPhase.completed) {
    return progress.taskCount == 0 ? '没有待下载任务' : '本轮下载完成';
  }
  final count = progress.taskCount > 0
      ? ' ${progress.taskIndex} / ${progress.taskCount}'
      : '';
  return '${_downloadProgressPhaseLabel(progress.phase)}$count';
}

String _downloadProgressPhaseLabel(DownloadProgressPhase phase) {
  return switch (phase) {
    DownloadProgressPhase.connecting => '正在连接服务器',
    DownloadProgressPhase.downloading => '正在下载',
    DownloadProgressPhase.processing => '正在处理下载内容',
    DownloadProgressPhase.completing => '正在写入本地文件',
    DownloadProgressPhase.failed => '当前文件下载失败',
    DownloadProgressPhase.completed => '下载完成',
    DownloadProgressPhase.idle => '等待下载',
  };
}

String _downloadProgressDetail(DownloadProgress progress) {
  if (progress.phase == DownloadProgressPhase.connecting) {
    return '正在请求远端文件';
  }
  if (progress.totalBytes > 0) {
    return '${_formatBytes(progress.downloadedBytes)} / ${_formatBytes(progress.totalBytes)}';
  }
  return _downloadProgressPhaseLabel(progress.phase);
}

IconData _downloadProgressIcon(DownloadProgressPhase phase) {
  return switch (phase) {
    DownloadProgressPhase.failed => Icons.error_outline,
    DownloadProgressPhase.completed => Icons.check_circle_outline,
    DownloadProgressPhase.connecting => Icons.cloud_sync_outlined,
    DownloadProgressPhase.downloading => Icons.cloud_download_outlined,
    DownloadProgressPhase.processing ||
    DownloadProgressPhase.completing => Icons.save_alt_outlined,
    DownloadProgressPhase.idle => Icons.cloud_queue_outlined,
  };
}

String _formatSpeed(int bytesPerSecond) {
  return '${_formatBytes(bytesPerSecond)}/秒';
}

String _uploadProgressTitle(UploadProgress progress) {
  if (progress.phase == UploadProgressPhase.completed) {
    if (progress.taskCount == 0) {
      return '没有待上传任务';
    }
    return progress.failedCount > 0 ? '本轮上传结束' : '本轮上传完成';
  }
  final count = progress.taskCount > 0
      ? ' ${progress.taskIndex} / ${progress.taskCount}'
      : '';
  return '${_uploadProgressPhaseLabel(progress.phase)}$count';
}

String _uploadProgressPhaseLabel(UploadProgressPhase phase) {
  return switch (phase) {
    UploadProgressPhase.preparing => '正在读取并处理',
    UploadProgressPhase.connecting => '正在连接服务器',
    UploadProgressPhase.uploading => '正在上传',
    UploadProgressPhase.completing => '正在确认上传',
    UploadProgressPhase.failed => '当前文件上传失败，继续处理',
    UploadProgressPhase.completed => '上传完成',
    UploadProgressPhase.idle => '等待上传',
  };
}

String _uploadProgressDetail(UploadProgress progress) {
  if (progress.phase == UploadProgressPhase.preparing) {
    if (progress.totalBytes > 0 && progress.uploadedBytes > 0) {
      return '已恢复 ${_formatBytes(progress.uploadedBytes)} / ${_formatBytes(progress.totalBytes)}，正在准备续传';
    }
    return '正在读取文件并生成上传内容';
  }
  if (progress.phase == UploadProgressPhase.connecting) {
    if (progress.totalBytes > 0 && progress.uploadedBytes > 0) {
      return '已恢复 ${_formatBytes(progress.uploadedBytes)} / ${_formatBytes(progress.totalBytes)}，正在连接服务器';
    }
    return '正在创建或恢复上传会话';
  }
  if (progress.totalBytes > 0) {
    return '${_formatBytes(progress.uploadedBytes)} / ${_formatBytes(progress.totalBytes)}';
  }
  return _uploadProgressPhaseLabel(progress.phase);
}

double? _uploadFileProgress(UploadProgress progress) {
  if (progress.totalBytes <= 0) {
    return null;
  }
  return (progress.uploadedBytes / progress.totalBytes).clamp(0.0, 1.0);
}

String _uploadProgressFileName(String path) {
  final parts = _pathParts(path);
  return parts.isEmpty ? path.trim() : parts.last;
}

IconData _uploadProgressIcon(UploadProgressPhase phase) {
  return switch (phase) {
    UploadProgressPhase.failed => Icons.error_outline,
    UploadProgressPhase.completed => Icons.check_circle_outline,
    UploadProgressPhase.preparing => Icons.lock_outline,
    UploadProgressPhase.connecting => Icons.cloud_sync_outlined,
    UploadProgressPhase.uploading ||
    UploadProgressPhase.completing => Icons.cloud_upload_outlined,
    UploadProgressPhase.idle => Icons.cloud_queue_outlined,
  };
}

Color _uploadProgressColor(ColorScheme colorScheme, UploadProgressPhase phase) {
  return switch (phase) {
    UploadProgressPhase.failed => colorScheme.error,
    UploadProgressPhase.completed => colorScheme.primary,
    _ => colorScheme.primary,
  };
}

class _SyncHomeLoadingSkeleton extends StatelessWidget {
  const _SyncHomeLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 88),
          children: [
            Text('正在加载同步目录', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              '正在读取本地状态并连接服务器',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            for (var index = 0; index < 3; index += 1) ...[
              _SyncRootSkeletonRow(color: colorScheme.surfaceContainerLow),
              if (index != 2) const SizedBox(height: 10),
            ],
          ],
        ),
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: LinearProgressIndicator(minHeight: 2),
        ),
      ],
    );
  }
}

class _WaitingForServerDirectories extends StatelessWidget {
  const _WaitingForServerDirectories();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Flexible(child: Text('正在获取服务器上的同步目录')),
        ],
      ),
    );
  }
}

class _SyncRootSkeletonRow extends StatelessWidget {
  final Color color;

  const _SyncRootSkeletonRow({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 82,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FractionallySizedBox(
                  widthFactor: 0.42,
                  child: Container(
                    height: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 10),
                FractionallySizedBox(
                  widthFactor: 0.7,
                  child: Container(
                    height: 9,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SlowServerNotice extends StatelessWidget {
  final bool showingLocalData;

  const _SlowServerNotice({required this.showingLocalData});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.cloud_sync_outlined, size: 18, color: colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            showingLocalData ? '服务器响应较慢，当前显示本地同步状态' : '服务器响应较慢，当前显示已加载的内容',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _InlineSyncWarning extends StatelessWidget {
  final String message;

  const _InlineSyncWarning({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 18, color: colorScheme.tertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _InlineSyncError extends StatelessWidget {
  final String message;

  const _InlineSyncError({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceFilterOption {
  static const currentId = '_current';
  static const allId = '_all';
  static const devicePrefix = 'device:';

  final String id;
  final String label;
  final int count;

  const _DeviceFilterOption({
    required this.id,
    required this.label,
    required this.count,
  });

  static List<_DeviceFilterOption> fromRootViews(
    List<_SyncRootViewData> rootViews,
  ) {
    if (rootViews.isEmpty) {
      return const [];
    }
    final currentCount = rootViews
        .where((rootView) => rootView.isCurrentDeviceRoot)
        .length;
    final deviceViews = <String, List<_SyncRootViewData>>{};
    for (final rootView in rootViews) {
      deviceViews.putIfAbsent(rootView.root.deviceId, () => []).add(rootView);
    }
    final hasOtherDevices = rootViews.any(
      (rootView) => !rootView.isCurrentDeviceRoot,
    );
    final options = <_DeviceFilterOption>[
      _DeviceFilterOption(id: currentId, label: '当前设备', count: currentCount),
    ];
    if (hasOtherDevices) {
      options.add(
        _DeviceFilterOption(id: allId, label: '全部设备', count: rootViews.length),
      );
      final otherDeviceEntries =
          [
            for (final entry in deviceViews.entries)
              if (entry.value.any((rootView) => !rootView.isCurrentDeviceRoot))
                entry,
          ]..sort(
            (left, right) => left.value.first.deviceDisplayName.compareTo(
              right.value.first.deviceDisplayName,
            ),
          );
      for (final entry in otherDeviceEntries) {
        final firstView = entry.value.first;
        options.add(
          _DeviceFilterOption(
            id: '$devicePrefix${entry.key}',
            label: firstView.deviceDisplayName,
            count: entry.value.length,
          ),
        );
      }
    }
    return options;
  }
}

class _DeviceFilterBar extends StatelessWidget {
  final List<_DeviceFilterOption> options;
  final String selectedId;
  final ValueChanged<String> onChanged;

  const _DeviceFilterBar({
    required this.options,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: const ValueKey('device_filter_dropdown'),
      initialValue: selectedId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '设备',
        prefixIcon: Icon(Icons.devices_outlined),
        border: OutlineInputBorder(),
      ),
      items: [
        for (final option in options)
          DropdownMenuItem(
            key: ValueKey('device_filter_${option.id}'),
            value: option.id,
            child: Text(
              '${option.label}（${option.count}）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) {
        if (value != null) {
          onChanged(value);
        }
      },
    );
  }
}

class _DeviceSyncStatusGroup extends StatelessWidget {
  final List<_SyncRootViewData> roots;

  const _DeviceSyncStatusGroup({required this.roots});

  @override
  Widget build(BuildContext context) {
    final first = roots.first;
    return Column(
      children: [
        ListTile(
          key: ValueKey('sync_status_device_${first.root.deviceId}'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.devices_outlined),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  first.deviceDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (first.isCurrentDeviceRoot) const _StatusBadge(label: '当前设备'),
            ],
          ),
          subtitle: Text('${roots.length} 个同步目录'),
        ),
        for (final root in roots)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        root.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '等待稳定 ${root.waitingStableTaskCount} · 待上传 ${root.pendingTaskCount} · 失败 ${root.failedTaskCount}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (root.operations.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          _rootOperationSummary(root),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _rootOperationSummary(_SyncRootViewData root) {
  final sorted = [...root.operations]
    ..sort((left, right) => right.startedAt.compareTo(left.startedAt));
  return sorted
      .take(2)
      .map((item) {
        final operation = item.operation == 'scan' ? '扫描' : '上传';
        final source = item.source == 'auto' ? '自动' : '手动';
        final status = switch (item.status) {
          'running' => '进行中',
          'success' => '完成',
          'failed' => '失败',
          _ => item.status,
        };
        return '$source$operation$status';
      })
      .join(' · ');
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
    final groups = <String, List<_SyncRootViewData>>{};
    for (final root in data.rootViews) {
      groups.putIfAbsent(root.root.deviceId, () => []).add(root);
    }
    final groupedRoots = groups.values.toList()
      ..sort((left, right) {
        final leftCurrent = left.first.isCurrentDeviceRoot;
        final rightCurrent = right.first.isCurrentDeviceRoot;
        if (leftCurrent != rightCurrent) {
          return leftCurrent ? -1 : 1;
        }
        return left.first.deviceDisplayName.compareTo(
          right.first.deviceDisplayName,
        );
      });
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
              Text('同步概览', style: Theme.of(context).textTheme.titleSmall),
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
                icon: Icons.hourglass_top_outlined,
                label: '等待写入完成',
                value: data.waitingStableTaskCount,
              ),
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
          const SizedBox(height: 10),
          _AutoSyncStatusLine(
            status: data.autoSyncStatus,
            enabled: autoSyncEnabled,
          ),
          if (groupedRoots.isNotEmpty) ...[
            const Divider(height: 24),
            Text('设备与同步目录', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (var index = 0; index < groupedRoots.length; index += 1) ...[
              _DeviceSyncStatusGroup(roots: groupedRoots[index]),
              if (index != groupedRoots.length - 1) const Divider(height: 20),
            ],
          ],
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
    if (data.waitingStableTaskCount > 0) {
      return '等待文件写入完成';
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

const _statusListPageSize = 40;
final _epochDateTime = DateTime.fromMillisecondsSinceEpoch(0);

class _StatusListPager extends StatelessWidget {
  final String keyPrefix;
  final int page;
  final int pageCount;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _StatusListPager({
    required this.keyPrefix,
    required this.page,
    required this.pageCount,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    if (pageCount <= 1) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            key: ValueKey('${keyPrefix}_previous'),
            tooltip: '上一页',
            onPressed: page == 0 ? null : onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          SizedBox(
            width: 88,
            child: Text(
              '第 ${page + 1} / $pageCount 页',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            key: ValueKey('${keyPrefix}_next'),
            tooltip: '下一页',
            onPressed: page >= pageCount - 1 ? null : onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

class _FailedUploadTaskList extends StatefulWidget {
  final _SyncHomeData data;
  final bool retryEnabled;
  final ValueChanged<String> onRetryRoot;

  const _FailedUploadTaskList({
    required this.data,
    required this.retryEnabled,
    required this.onRetryRoot,
  });

  @override
  State<_FailedUploadTaskList> createState() => _FailedUploadTaskListState();
}

class _FailedUploadTaskListState extends State<_FailedUploadTaskList> {
  var _page = 0;

  @override
  Widget build(BuildContext context) {
    final failedItems = <({String rootName, LocalUploadTask task})>[
      for (final rootView in widget.data.rootViews)
        for (final task in rootView.tasks)
          if (task.status == 'failed')
            (rootName: rootView.displayName, task: task),
    ];
    if (failedItems.isEmpty) {
      return const _StatusEmptyState();
    }
    final pageCount = (failedItems.length / _statusListPageSize).ceil();
    final page = _page.clamp(0, pageCount - 1);
    final start = page * _statusListPageSize;
    final pageItems = failedItems.sublist(
      start,
      math.min(start + _statusListPageSize, failedItems.length),
    );
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
        for (final item in pageItems)
          Card(
            key: ValueKey('failed_upload_task_${item.task.id}'),
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
                onPressed: widget.retryEnabled
                    ? () => widget.onRetryRoot(item.task.syncRootId)
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('重试此目录'),
              ),
            ),
          ),
        _StatusListPager(
          keyPrefix: 'failed_uploads',
          page: page,
          pageCount: pageCount,
          onPrevious: () => setState(() => _page = page - 1),
          onNext: () => setState(() => _page = page + 1),
        ),
      ],
    );
  }
}

class _CleanupPendingTaskList extends StatefulWidget {
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
  State<_CleanupPendingTaskList> createState() =>
      _CleanupPendingTaskListState();
}

class _CleanupPendingTaskListState extends State<_CleanupPendingTaskList> {
  var _page = 0;

  @override
  Widget build(BuildContext context) {
    final mediaCleanupItems = <({String rootName, LocalUploadTask task})>[
      for (final rootView in widget.data.rootViews)
        for (final task in rootView.tasks)
          if (_taskNeedsLocalCleanup(task, rootView.root.cleanupPolicy) &&
              task.sourceType == 'media_asset')
            (rootName: rootView.displayName, task: task),
    ];
    final fileCleanupItems = <({String rootName, LocalUploadTask task})>[
      for (final rootView in widget.data.rootViews)
        for (final task in rootView.tasks)
          if (_taskNeedsLocalCleanup(task, rootView.root.cleanupPolicy) &&
              task.sourceType != 'media_asset')
            (rootName: rootView.displayName, task: task),
    ];
    if (mediaCleanupItems.isEmpty && fileCleanupItems.isEmpty) {
      return const SizedBox.shrink();
    }
    final pageCount = (fileCleanupItems.length / _statusListPageSize).ceil();
    final page = pageCount == 0 ? 0 : _page.clamp(0, pageCount - 1);
    final start = page * _statusListPageSize;
    final pageItems = fileCleanupItems.isEmpty
        ? const <({String rootName, LocalUploadTask task})>[]
        : fileCleanupItems.sublist(
            start,
            math.min(start + _statusListPageSize, fileCleanupItems.length),
          );
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
                  onPressed: widget.onOpenMediaCleanupPage,
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
                  onPressed: widget.onRetryCleanup,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试清理'),
                ),
              ],
            ),
          ),
        for (final item in pageItems)
          Card(
            key: ValueKey('cleanup_pending_task_${item.task.id}'),
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
                      widget.onRetryOne?.call(item.task.id);
                    case _CleanupTaskAction.ignore:
                      widget.onIgnoreOne?.call(item.task.id);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _CleanupTaskAction.retry,
                    enabled: widget.onRetryOne != null,
                    child: const Text('重试此项'),
                  ),
                  PopupMenuItem(
                    value: _CleanupTaskAction.ignore,
                    enabled: widget.onIgnoreOne != null,
                    child: const Text('忽略此项'),
                  ),
                ],
              ),
            ),
          ),
        _StatusListPager(
          keyPrefix: 'cleanup_pending',
          page: page,
          pageCount: pageCount,
          onPrevious: () => setState(() => _page = page - 1),
          onNext: () => setState(() => _page = page + 1),
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
  final Set<String> _completedTaskIds = {};
  final Set<String> _ignoredTaskIds = {};
  var _isConfirming = false;
  var _hasChanges = false;
  var _page = 0;

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
      _ignoredTaskIds.add(taskId);
      _hasChanges = true;
    });
  }

  Future<void> _confirmAll() async {
    final taskIds = _mediaCleanupItems
        .map((item) => item.task.id)
        .toList(growable: false);
    if (taskIds.isEmpty || _isConfirming) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认批量清理 ${taskIds.length} 个相册资源？'),
        content: const Text(
          '只会提交已经完成服务器备份的照片和视频。数量较多时系统可能分批显示删除确认，无需回到列表重复操作；服务器上的加密备份不会被删除。',
        ),
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
      final result = await widget.onConfirmCleanup(taskIds);
      if (!mounted) {
        return;
      }
      final remainingCount = _mediaCleanupItems
          .where((item) => !result.cleanedTaskIds.contains(item.task.id))
          .length;
      setState(() {
        _completedTaskIds.addAll(result.cleanedTaskIds);
        if (result.cleanedTaskIds.isNotEmpty) {
          _hasChanges = true;
        }
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
    final pageCount = (items.length / _statusListPageSize).ceil();
    final page = pageCount == 0 ? 0 : _page.clamp(0, pageCount - 1);
    final start = page * _statusListPageSize;
    final pageItems = items.isEmpty
        ? const <({String rootName, LocalUploadTask task})>[]
        : items.sublist(
            start,
            math.min(start + _statusListPageSize, items.length),
          );
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          Navigator.of(context).pop(_hasChanges);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('待清理照片和视频'),
          automaticallyImplyLeading: false,
          leading: IconButton(
            key: const ValueKey('close_media_cleanup_button'),
            tooltip: '返回同步状态',
            onPressed: () => Navigator.of(context).pop(_hasChanges),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          children: [
            Text(
              '这些是旧版本留下的待清理任务。无需逐项选择，一次确认即可批量提交；文件名编码异常的项目会继续保留。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusBadge(label: '待清理总数 ${items.length}'),
                const _StatusBadge(label: '一次确认批量处理'),
              ],
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('暂无待清理照片和视频')),
              )
            else
              for (final item in pageItems)
                Card(
                  key: ValueKey('media_cleanup_select_${item.task.id}'),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.photo_outlined),
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
            _StatusListPager(
              keyPrefix: 'media_cleanup',
              page: page,
              pageCount: pageCount,
              onPrevious: () => setState(() => _page = page - 1),
              onNext: () => setState(() => _page = page + 1),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            key: const ValueKey('confirm_media_cleanup_button'),
            onPressed: items.isEmpty || _isConfirming ? null : _confirmAll,
            icon: _isConfirming
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline),
            label: Text(items.isEmpty ? '暂无待清理项目' : '全部清理 ${items.length} 个'),
          ),
        ),
      ),
    );
  }
}

class _OpenSyncIssueList extends StatefulWidget {
  final _SyncHomeData data;
  final bool batchEnabled;
  final ValueChanged<LocalSyncIssue> onOpenIssue;
  final VoidCallback onEnqueueAllConflicts;
  final VoidCallback onResolveAllConflicts;

  const _OpenSyncIssueList({
    required this.data,
    required this.batchEnabled,
    required this.onOpenIssue,
    required this.onEnqueueAllConflicts,
    required this.onResolveAllConflicts,
  });

  @override
  State<_OpenSyncIssueList> createState() => _OpenSyncIssueListState();
}

class _OpenSyncIssueListState extends State<_OpenSyncIssueList> {
  var _page = 0;

  @override
  Widget build(BuildContext context) {
    final issues = widget.data.openIssues;
    if (issues.isEmpty) {
      return const SizedBox.shrink();
    }
    final conflictCount = issues
        .where((issue) => issue.type == 'download_conflict')
        .length;
    final pageCount = (issues.length / _statusListPageSize).ceil();
    final page = _page.clamp(0, pageCount - 1);
    final start = page * _statusListPageSize;
    final pageIssues = issues.sublist(
      start,
      math.min(start + _statusListPageSize, issues.length),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '待处理问题 ${issues.length} 个',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (conflictCount > 0)
                Text(
                  '冲突 $conflictCount 个',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
            ],
          ),
        ),
        if (conflictCount > 0) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('enqueue_all_conflicts_button'),
                  onPressed: widget.batchEnabled
                      ? widget.onEnqueueAllConflicts
                      : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('全部上传冲突副本'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('resolve_all_conflicts_button'),
                  onPressed: widget.batchEnabled
                      ? widget.onResolveAllConflicts
                      : null,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('全部关闭冲突提醒'),
                ),
              ],
            ),
          ),
        ],
        for (final issue in pageIssues)
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
              onTap: () => widget.onOpenIssue(issue),
            ),
          ),
        _StatusListPager(
          keyPrefix: 'sync_issues',
          page: page,
          pageCount: pageCount,
          onPrevious: () => setState(() => _page = page - 1),
          onNext: () => setState(() => _page = page + 1),
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
      Navigator.of(context).pop(true);
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

class _SyncRootPanel extends StatefulWidget {
  final _SyncRootViewData rootView;
  final bool initiallyExpanded;
  final String? focusPath;
  final FileBrowserPreferenceStore? fileBrowserPreferences;
  final MediaAssetThumbnailGateway? mediaThumbnails;
  final RemoteFileThumbnailGateway? remoteFileThumbnails;
  final VoidCallback? onManage;
  final VoidCallback? onScan;
  final VoidCallback? onBind;
  final VoidCallback? onUpload;
  final VoidCallback? onRetryFailed;
  final ValueChanged<_UnifiedFileRecord>? onDeleteFile;
  final ValueChanged<String>? onDeleteFolder;
  final ValueChanged<_UnifiedFileRecord>? onPreviewFile;
  final ValueChanged<_UnifiedFileRecord>? onDownloadFile;
  final ValueChanged<_UnifiedFileRecord>? onShowFileDetails;
  final VoidCallback? onShowDetails;

  const _SyncRootPanel({
    super.key,
    required this.rootView,
    required this.initiallyExpanded,
    required this.focusPath,
    required this.fileBrowserPreferences,
    required this.mediaThumbnails,
    required this.remoteFileThumbnails,
    required this.onManage,
    required this.onScan,
    required this.onBind,
    required this.onUpload,
    required this.onRetryFailed,
    required this.onDeleteFile,
    required this.onDeleteFolder,
    required this.onPreviewFile,
    required this.onDownloadFile,
    required this.onShowFileDetails,
    required this.onShowDetails,
  });

  @override
  State<_SyncRootPanel> createState() => _SyncRootPanelState();
}

class _SyncRootPanelState extends State<_SyncRootPanel> {
  static const _contentLoadDelay = Duration(milliseconds: 220);

  Timer? _contentLoadTimer;
  var _contentReady = false;

  @override
  void initState() {
    super.initState();
    if (widget.initiallyExpanded) {
      _scheduleContentLoad();
    }
  }

  _SyncRootViewData get rootView => widget.rootView;
  bool get initiallyExpanded => widget.initiallyExpanded;
  String? get focusPath => widget.focusPath;
  FileBrowserPreferenceStore? get fileBrowserPreferences =>
      widget.fileBrowserPreferences;
  MediaAssetThumbnailGateway? get mediaThumbnails => widget.mediaThumbnails;
  RemoteFileThumbnailGateway? get remoteFileThumbnails =>
      widget.remoteFileThumbnails;
  VoidCallback? get onManage => widget.onManage;
  VoidCallback? get onScan => widget.onScan;
  VoidCallback? get onBind => widget.onBind;
  VoidCallback? get onUpload => widget.onUpload;
  VoidCallback? get onRetryFailed => widget.onRetryFailed;
  ValueChanged<_UnifiedFileRecord>? get onDeleteFile => widget.onDeleteFile;
  ValueChanged<String>? get onDeleteFolder => widget.onDeleteFolder;
  ValueChanged<_UnifiedFileRecord>? get onPreviewFile => widget.onPreviewFile;
  ValueChanged<_UnifiedFileRecord>? get onDownloadFile => widget.onDownloadFile;
  ValueChanged<_UnifiedFileRecord>? get onShowFileDetails =>
      widget.onShowFileDetails;
  VoidCallback? get onShowDetails => widget.onShowDetails;

  @override
  void didUpdateWidget(covariant _SyncRootPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initiallyExpanded &&
        !_contentReady &&
        _contentLoadTimer == null) {
      _scheduleContentLoad();
    }
  }

  @override
  void dispose() {
    _contentLoadTimer?.cancel();
    super.dispose();
  }

  void _handleExpansionChanged(bool expanded) {
    if (!expanded) {
      _contentLoadTimer?.cancel();
      _contentLoadTimer = null;
      return;
    }
    if (_contentReady || _contentLoadTimer != null) {
      return;
    }
    _scheduleContentLoad();
  }

  void _scheduleContentLoad() {
    _contentLoadTimer = Timer(_contentLoadDelay, () {
      _contentLoadTimer = null;
      if (!mounted) {
        return;
      }
      setState(() => _contentReady = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        onExpansionChanged: _handleExpansionChanged,
        tilePadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        leading: Icon(
          rootView.isCurrentDeviceRoot
              ? Icons.folder_outlined
              : Icons.folder_shared_outlined,
          color: rootView.isCurrentDeviceRoot
              ? colorScheme.primary
              : colorScheme.outline,
        ),
        title: Text(
          rootView.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              rootView.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    rootView.deviceLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: rootView.isCurrentDeviceRoot
                          ? colorScheme.primary
                          : colorScheme.outline,
                    ),
                  ),
                ),
                if (!rootView.isCurrentDeviceRoot) ...[
                  const SizedBox(width: 6),
                  const _StatusBadge(label: '只读'),
                ],
                const SizedBox(width: 6),
                _StatusBadge(label: rootView.statusLabel),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<_SyncRootQuickAction>(
              key: ValueKey('sync_root_quick_actions_${rootView.root.id}'),
              tooltip: '目录操作',
              onSelected: (action) {
                switch (action) {
                  case _SyncRootQuickAction.details:
                    onShowDetails?.call();
                  case _SyncRootQuickAction.bind:
                    onBind?.call();
                  case _SyncRootQuickAction.scan:
                    onScan?.call();
                  case _SyncRootQuickAction.upload:
                    onUpload?.call();
                  case _SyncRootQuickAction.retryFailed:
                    onRetryFailed?.call();
                }
              },
              itemBuilder: (context) {
                final items = <PopupMenuEntry<_SyncRootQuickAction>>[
                  if (onShowDetails != null)
                    const PopupMenuItem(
                      value: _SyncRootQuickAction.details,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.info_outline),
                        title: Text('目录详情'),
                      ),
                    ),
                ];
                if (!rootView.isCurrentDeviceRoot) {
                  items.add(
                    const PopupMenuItem(
                      enabled: false,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.visibility_outlined),
                        title: Text('其他设备目录仅可查看'),
                      ),
                    ),
                  );
                  return items;
                }
                items.addAll([
                  if (rootView.canBindLocalPath)
                    PopupMenuItem(
                      value: _SyncRootQuickAction.bind,
                      enabled: onBind != null,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.folder_open_outlined),
                        title: Text(
                          rootView.isWechatBackupRoot ? '绑定微信目录' : '绑定本地目录',
                        ),
                      ),
                    ),
                  PopupMenuItem(
                    value: _SyncRootQuickAction.scan,
                    enabled: onScan != null,
                    child: const ListTile(
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
                ]);
                return items;
              },
            ),
            if (onManage != null)
              IconButton(
                key: ValueKey('manage_sync_root_${rootView.root.id}'),
                tooltip: '管理同步目录',
                onPressed: onManage,
                icon: const Icon(Icons.settings_outlined),
              ),
          ],
        ),
        children: [
          if (!_contentReady)
            const _DeferredRootContentIndicator()
          else ...[
            _RootMetaRow(rootView: rootView),
            if (!rootView.isCurrentDeviceRoot) ...[
              const SizedBox(height: 8),
              _ReadOnlyDeviceNotice(deviceLine: rootView.deviceLine),
            ],
            const SizedBox(height: 8),
            if (rootView.fileEntries.isEmpty)
              _EmptyFileHint(
                message: rootView.canBindLocalPath
                    ? '尚未绑定本机目录，请先绑定微信目录后再扫描。'
                    : null,
              )
            else
              _UnifiedFileTree(
                rootView: rootView,
                focusPath: focusPath,
                preferences: fileBrowserPreferences,
                mediaThumbnails: mediaThumbnails,
                remoteFileThumbnails: remoteFileThumbnails,
                onDeleteFile: onDeleteFile,
                onDeleteFolder: onDeleteFolder,
                onPreviewFile: onPreviewFile,
                onDownloadFile: onDownloadFile,
                onShowFileDetails: onShowFileDetails,
              ),
          ],
        ],
      ),
    );
  }
}

class _DeferredRootContentIndicator extends StatelessWidget {
  const _DeferredRootContentIndicator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('正在加载目录…'),
        ],
      ),
    );
  }
}

class _TreeIndexLoadingIndicator extends StatelessWidget {
  const _TreeIndexLoadingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('正在整理目录…'),
        ],
      ),
    );
  }
}

enum _SyncRootQuickAction { details, bind, scan, upload, retryFailed }

class _RootMetaRow extends StatelessWidget {
  final _SyncRootViewData rootView;

  const _RootMetaRow({required this.rootView});

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (rootView.pendingTaskCount > 0)
        _MetaChip(
          icon: Icons.cloud_upload_outlined,
          label: '待上传 ${rootView.pendingTaskCount}',
        ),
      _MetaChip(
        icon: Icons.insert_drive_file_outlined,
        label: '${rootView.fileEntries.length} 个文件',
      ),
      if (rootView.waitingStableTaskCount > 0)
        _MetaChip(
          icon: Icons.hourglass_top_outlined,
          label: '等待写入 ${rootView.waitingStableTaskCount}',
        ),
      if (rootView.failedTaskCount > 0)
        _MetaChip(
          icon: Icons.error_outline,
          label: '上传失败 ${rootView.failedTaskCount}',
        ),
      if (rootView.issues.isNotEmpty)
        _MetaChip(
          icon: Icons.error_outline,
          label: '问题 ${rootView.issues.length}',
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final stretched = constraints.maxWidth >= 700 && chips.length > 1;
        if (stretched) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < chips.length; index += 1) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(
                  child: _MetaChip(
                    icon: (chips[index] as _MetaChip).icon,
                    label: (chips[index] as _MetaChip).label,
                    expanded: true,
                  ),
                ),
              ],
            ],
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.start,
          children: chips,
        );
      },
    );
  }
}

class _SyncRootDetailsSheet extends StatelessWidget {
  final _SyncRootViewData rootView;

  const _SyncRootDetailsSheet({required this.rootView});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('目录详情', style: textTheme.titleLarge)),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(rootView.displayName, style: textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(rootView.subtitle, style: textTheme.bodyMedium),
            Text(
              rootView.deviceLine,
              style: textTheme.bodySmall?.copyWith(
                color: rootView.isCurrentDeviceRoot
                    ? colorScheme.primary
                    : colorScheme.outline,
              ),
            ),
            const SizedBox(height: 18),
            _SyncRootDetailsSection(
              title: '同步状态',
              children: [
                _SyncRootDetailLine(label: '当前状态', value: rootView.statusLabel),
                _SyncRootDetailLine(
                  label: '文件总数',
                  value: '${rootView.fileEntries.length} 个',
                ),
                if (rootView.pendingTaskCount > 0)
                  _SyncRootDetailLine(
                    label: '待上传',
                    value: '${rootView.pendingTaskCount} 个',
                  ),
                if (rootView.waitingStableTaskCount > 0)
                  _SyncRootDetailLine(
                    label: '等待写入完成',
                    value: '${rootView.waitingStableTaskCount} 个',
                  ),
                if (rootView.failedTaskCount > 0)
                  _SyncRootDetailLine(
                    label: '上传失败',
                    value: '${rootView.failedTaskCount} 个',
                  ),
                if (rootView.issues.isNotEmpty)
                  _SyncRootDetailLine(
                    label: '待处理问题',
                    value: '${rootView.issues.length} 个',
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _SyncRootDetailsSection(
              title: '存储与清理',
              children: [
                _SyncRootDetailLine(
                  label: '存储方式',
                  value: rootView.root.encryptionEnabled ? '加密' : '普通',
                ),
                _SyncRootDetailLine(
                  label: '清理策略',
                  value: _cleanupPolicyLabel(rootView.root.cleanupPolicy),
                ),
                if (rootView.backedUpDeletedLocalCount > 0)
                  _SyncRootDetailLine(
                    label: '本地已清理',
                    value: '${rootView.backedUpDeletedLocalCount} 个',
                  ),
              ],
            ),
            if (rootView.shouldShowDeletePolicyNotice) ...[
              const SizedBox(height: 14),
              Text(
                '删除策略下，${rootView.backedUpDeletedLocalCount} 个文件已完成服务器备份，本地已按策略清理。',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SyncRootDetailsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SyncRootDetailsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        ...children,
      ],
    );
  }
}

class _SyncRootDetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _SyncRootDetailLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool expanded;

  const _MetaChip({
    required this.icon,
    required this.label,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: expanded ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.centerLeft,
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

class _ReadOnlyDeviceNotice extends StatelessWidget {
  final String deviceLine;

  const _ReadOnlyDeviceNotice({required this.deviceLine});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.visibility_outlined, size: 18, color: colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(child: Text('$deviceLine。此目录不是当前设备创建的，只能查看服务器备份和状态。')),
        ],
      ),
    );
  }
}

class _UnifiedFileTree extends StatefulWidget {
  final _SyncRootViewData rootView;
  final String? focusPath;
  final FileBrowserPreferenceStore? preferences;
  final MediaAssetThumbnailGateway? mediaThumbnails;
  final RemoteFileThumbnailGateway? remoteFileThumbnails;
  final ValueChanged<_UnifiedFileRecord>? onDeleteFile;
  final ValueChanged<String>? onDeleteFolder;
  final ValueChanged<_UnifiedFileRecord>? onPreviewFile;
  final ValueChanged<_UnifiedFileRecord>? onDownloadFile;
  final ValueChanged<_UnifiedFileRecord>? onShowFileDetails;

  const _UnifiedFileTree({
    required this.rootView,
    required this.focusPath,
    required this.preferences,
    required this.mediaThumbnails,
    required this.remoteFileThumbnails,
    required this.onDeleteFile,
    required this.onDeleteFolder,
    required this.onPreviewFile,
    required this.onDownloadFile,
    required this.onShowFileDetails,
  });

  @override
  State<_UnifiedFileTree> createState() => _UnifiedFileTreeState();
}

class _UnifiedFileTreeState extends State<_UnifiedFileTree> {
  static const _entryBatchSize = 80;
  static const _gridEntryBatchSize = 24;

  var _visibleEntryLimit = _entryBatchSize;
  var _viewMode = _FileViewMode.list;
  var _sortMode = _FileSortMode.name;
  var _sortAscending = true;
  var _preferencesChanged = false;
  var _currentDirectory = '';
  List<_UnifiedFileRecord>? _cachedFilteredFiles;
  _UnifiedFolderSummaries? _cachedFolderSummaries;
  List<_UnifiedTreeEntry>? _cachedDirectoryEntries;
  var _folderSummaryGeneration = 0;

  @override
  void initState() {
    super.initState();
    final focusPath = widget.focusPath;
    if (focusPath != null && focusPath.isNotEmpty) {
      final parts = _pathParts(focusPath);
      _currentDirectory = parts.length <= 1
          ? ''
          : parts.take(parts.length - 1).join('/');
    }
    unawaited(_restorePreferences());
    unawaited(_prepareFolderSummaries());
  }

  Future<void> _prepareFolderSummaries() async {
    final generation = ++_folderSummaryGeneration;
    if (!mounted || generation != _folderSummaryGeneration) {
      return;
    }
    final files = widget.rootView.fileEntries;
    final summaries = files.length <= 128
        ? _UnifiedFolderSummaries.fromFiles(files, widget.rootView)
        : await _UnifiedFolderSummaries.fromFilesAsync(files, widget.rootView);
    if (!mounted || generation != _folderSummaryGeneration) {
      return;
    }
    setState(() {
      _cachedFolderSummaries = summaries;
    });
  }

  Future<void> _restorePreferences() async {
    final store = widget.preferences;
    if (store == null) {
      return;
    }
    final preferences = await store.loadFileBrowserPreferences();
    if (!mounted || _preferencesChanged) {
      return;
    }
    final hasValidSortMode = _FileSortMode.values.any(
      (mode) => mode.name == preferences.sortMode,
    );
    setState(() {
      _viewMode = _fileViewModeFromName(preferences.viewMode);
      _sortMode = _fileSortModeFromName(preferences.sortMode);
      _sortAscending = hasValidSortMode ? preferences.sortAscending : true;
      _visibleEntryLimit = _batchSizeFor(_viewMode);
      _invalidateSortedEntries();
    });
  }

  void _savePreferences() {
    _preferencesChanged = true;
    final store = widget.preferences;
    if (store == null) {
      return;
    }
    unawaited(
      store.saveFileBrowserPreferences(
        FileBrowserPreferences(
          viewMode: _viewMode.name,
          sortMode: _sortMode.name,
          sortAscending: _sortAscending,
        ),
      ),
    );
  }

  void _selectSortMode(_FileSortMode mode) {
    setState(() {
      if (_sortMode == mode) {
        _sortAscending = !_sortAscending;
      } else {
        _sortMode = mode;
        _sortAscending = mode == _FileSortMode.name;
      }
      _visibleEntryLimit = _batchSizeFor(_viewMode);
      _invalidateSortedEntries();
    });
    _savePreferences();
  }

  void _toggleSortDirection() {
    setState(() {
      _sortAscending = !_sortAscending;
      _visibleEntryLimit = _batchSizeFor(_viewMode);
      _invalidateSortedEntries();
    });
    _savePreferences();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _UnifiedFileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rootView, widget.rootView)) {
      _cachedFilteredFiles = null;
      _cachedFolderSummaries = null;
      _cachedDirectoryEntries = null;
      unawaited(_prepareFolderSummaries());
    }
    if (oldWidget.focusPath != widget.focusPath &&
        widget.focusPath != null &&
        widget.focusPath!.isNotEmpty) {
      _focusPath(widget.focusPath!);
    }
  }

  void _focusPath(String path) {
    final parts = _pathParts(path);
    final directory = parts.length <= 1
        ? ''
        : parts.take(parts.length - 1).join('/');
    setState(() {
      _currentDirectory = directory;
      _visibleEntryLimit = _batchSizeFor(_viewMode);
      _invalidateDirectoryEntries();
    });
  }

  void _invalidateSortedEntries() {
    _cachedFilteredFiles = null;
    _cachedDirectoryEntries = null;
  }

  void _invalidateDirectoryEntries() {
    _cachedDirectoryEntries = null;
  }

  void _openDirectory(String path) {
    setState(() {
      _currentDirectory = path;
      _visibleEntryLimit = _batchSizeFor(_viewMode);
      _invalidateDirectoryEntries();
    });
  }

  int _batchSizeFor(_FileViewMode mode) {
    return mode == _FileViewMode.grid ? _gridEntryBatchSize : _entryBatchSize;
  }

  void _navigateToRoot() => _openDirectory('');

  void _navigateUp() {
    final parts = _pathParts(_currentDirectory);
    if (parts.isEmpty) {
      return;
    }
    _openDirectory(parts.take(parts.length - 1).join('/'));
  }

  List<_UnifiedFileRecord> _filteredSortedFiles() {
    final cached = _cachedFilteredFiles;
    if (cached != null) {
      return cached;
    }
    if (_sortMode == _FileSortMode.name && _sortAscending) {
      return _cachedFilteredFiles = widget.rootView.fileEntries;
    }
    final files = widget.rootView.fileEntries.toList();
    if (_sortMode != _FileSortMode.name || !_sortAscending) {
      files.sort((left, right) {
        final result = switch (_sortMode) {
          _FileSortMode.name => left.path.compareTo(right.path),
          _FileSortMode.size =>
            (right.backup?.sizeBytes ?? right.task?.sizeBytes ?? 0).compareTo(
              left.backup?.sizeBytes ?? left.task?.sizeBytes ?? 0,
            ),
          _FileSortMode.updated => _fileUpdatedAt(
            right,
          ).compareTo(_fileUpdatedAt(left)),
          _FileSortMode.status =>
            widget.rootView
                .fileStatusLabel(left)
                .compareTo(widget.rootView.fileStatusLabel(right)),
        };
        final compared = result == 0 ? left.path.compareTo(right.path) : result;
        return _sortAscending ? compared : -compared;
      });
    }
    return _cachedFilteredFiles = files;
  }

  DateTime _fileUpdatedAt(_UnifiedFileRecord file) {
    return _unifiedFileUpdatedAt(file);
  }

  Future<void> _showFileProperties(_UnifiedFileRecord file) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _FilePropertiesDialog(
        file: file,
        rootView: widget.rootView,
        statusLabel: widget.rootView.fileStatusLabel(file),
      ),
    );
  }

  List<_UnifiedTreeEntry> _directoryEntries(
    List<_UnifiedFileRecord> files,
    _UnifiedFolderSummaries folderSummaries,
  ) {
    final cached = _cachedDirectoryEntries;
    if (cached != null) {
      return cached;
    }
    final entries = <_UnifiedTreeEntry>[
      ...(folderSummaries.entriesByDirectory[_currentDirectory] ?? const []),
    ];
    entries.sort((left, right) {
      final leftFolder = left is _UnifiedFolderEntry;
      final rightFolder = right is _UnifiedFolderEntry;
      if (leftFolder != rightFolder) {
        return leftFolder ? -1 : 1;
      }
      final result = switch (_sortMode) {
        _FileSortMode.name => left.name.compareTo(right.name),
        _FileSortMode.size => _entrySize(
          right,
          folderSummaries,
        ).compareTo(_entrySize(left, folderSummaries)),
        _FileSortMode.updated => _entryUpdatedAt(
          right,
          folderSummaries,
        ).compareTo(_entryUpdatedAt(left, folderSummaries)),
        _FileSortMode.status => _entryStatus(
          left,
          folderSummaries,
        ).compareTo(_entryStatus(right, folderSummaries)),
      };
      final compared = result == 0 ? left.path.compareTo(right.path) : result;
      return _sortAscending ? compared : -compared;
    });
    return _cachedDirectoryEntries = entries;
  }

  int _entrySize(
    _UnifiedTreeEntry entry,
    _UnifiedFolderSummaries folderSummaries,
  ) {
    if (entry case _UnifiedFolderEntry()) {
      return folderSummaries.byPath[entry.path]?.sizeBytes ?? 0;
    }
    final file = (entry as _UnifiedFileEntry).file;
    return file.backup?.sizeBytes ?? file.task?.sizeBytes ?? 0;
  }

  String _entryStatus(
    _UnifiedTreeEntry entry,
    _UnifiedFolderSummaries folderSummaries,
  ) {
    if (entry case _UnifiedFolderEntry()) {
      return folderSummaries.byPath[entry.path]?.statusLabel ?? '';
    }
    return widget.rootView.fileStatusLabel((entry as _UnifiedFileEntry).file);
  }

  DateTime _entryUpdatedAt(
    _UnifiedTreeEntry entry,
    _UnifiedFolderSummaries folderSummaries,
  ) {
    if (entry case _UnifiedFolderEntry()) {
      return folderSummaries.byPath[entry.path]?.updatedAt ?? _epochDateTime;
    }
    return _fileUpdatedAt((entry as _UnifiedFileEntry).file);
  }

  @override
  Widget build(BuildContext context) {
    final folderSummaries = _cachedFolderSummaries;
    if (folderSummaries == null) {
      return const _TreeIndexLoadingIndicator();
    }
    final files = _filteredSortedFiles();
    final allVisibleEntries = _directoryEntries(files, folderSummaries);
    final visibleEntries = allVisibleEntries
        .take(_visibleEntryLimit)
        .toList(growable: false);
    final hiddenCount = allVisibleEntries.length - visibleEntries.length;
    return Column(
      children: [
        _DirectoryBreadcrumbs(
          rootName: widget.rootView.displayName,
          currentPath: _currentDirectory,
          onRoot: _navigateToRoot,
          onUp: _navigateUp,
          onSegment: _openDirectory,
        ),
        _FileTreeToolbar(
          viewMode: _viewMode,
          sortMode: _sortMode,
          sortAscending: _sortAscending,
          itemCount: allVisibleEntries.length,
          totalFileCount: widget.rootView.fileEntries.length,
          onViewModeChanged: (mode) {
            setState(() {
              _viewMode = mode;
              _visibleEntryLimit = _batchSizeFor(mode);
            });
            _savePreferences();
          },
          onSortModeChanged: _selectSortMode,
          onSortDirectionChanged: _toggleSortDirection,
        ),
        if (_viewMode == _FileViewMode.grid)
          _buildGridEntries(visibleEntries, folderSummaries)
        else if (_viewMode == _FileViewMode.details)
          _buildDetailsEntries(visibleEntries, folderSummaries)
        else
          for (final entry in visibleEntries)
            _buildListEntry(entry, folderSummaries),
        if (hiddenCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              key: ValueKey('load_more_files_${widget.rootView.root.id}'),
              onPressed: () {
                setState(() {
                  _visibleEntryLimit += _batchSizeFor(_viewMode);
                });
              },
              icon: const Icon(Icons.expand_more),
              label: Text(
                '继续显示 ${hiddenCount > _batchSizeFor(_viewMode) ? _batchSizeFor(_viewMode) : hiddenCount} 项',
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildListEntry(
    _UnifiedTreeEntry entry,
    _UnifiedFolderSummaries folderSummaries,
  ) {
    return switch (entry) {
      _UnifiedFolderEntry() => _UnifiedFolderRow(
        entry: entry,
        summary: folderSummaries.byPath[entry.path]!,
        expanded: false,
        onToggle: () => _openDirectory(entry.path),
        onDelete: widget.onDeleteFolder == null
            ? null
            : () => widget.onDeleteFolder?.call(entry.path),
      ),
      _UnifiedFileEntry() => _UnifiedFileRow(
        entry: entry,
        statusLabel: widget.rootView.fileStatusLabel(entry.file),
        onPreview: entry.file.canPreview && widget.onPreviewFile != null
            ? () => widget.onPreviewFile?.call(entry.file)
            : null,
        onDownload: entry.file.canDownload && widget.onDownloadFile != null
            ? () => widget.onDownloadFile?.call(entry.file)
            : null,
        onDelete: widget.onDeleteFile == null
            ? null
            : () => widget.onDeleteFile?.call(entry.file),
        onDetails: widget.onShowFileDetails == null
            ? () => _showFileProperties(entry.file)
            : () => widget.onShowFileDetails!.call(entry.file),
      ),
    };
  }

  Widget _buildDetailsEntries(
    List<_UnifiedTreeEntry> entries,
    _UnifiedFolderSummaries folderSummaries,
  ) {
    return Column(
      children: [
        _DetailsHeader(
          sortMode: _sortMode,
          sortAscending: _sortAscending,
          onSortModeChanged: _selectSortMode,
        ),
        for (final entry in entries)
          switch (entry) {
            _UnifiedFolderEntry() => _UnifiedDetailsFolderRow(
              entry: entry,
              summary: folderSummaries.byPath[entry.path]!,
              expanded: false,
              onToggle: () => _openDirectory(entry.path),
              onDelete: widget.onDeleteFolder == null
                  ? null
                  : () => widget.onDeleteFolder?.call(entry.path),
            ),
            _UnifiedFileEntry() => _UnifiedDetailsFileRow(
              entry: entry,
              statusLabel: widget.rootView.fileStatusLabel(entry.file),
              onPreview: entry.file.canPreview && widget.onPreviewFile != null
                  ? () => widget.onPreviewFile?.call(entry.file)
                  : null,
              onDownload:
                  entry.file.canDownload && widget.onDownloadFile != null
                  ? () => widget.onDownloadFile?.call(entry.file)
                  : null,
              onDelete: widget.onDeleteFile == null
                  ? null
                  : () => widget.onDeleteFile?.call(entry.file),
              onDetails: widget.onShowFileDetails == null
                  ? () => _showFileProperties(entry.file)
                  : () => widget.onShowFileDetails!.call(entry.file),
            ),
          },
      ],
    );
  }

  Widget _buildGridEntries(
    List<_UnifiedTreeEntry> entries,
    _UnifiedFolderSummaries folderSummaries,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final tileWidth = width >= 760
            ? 176.0
            : width >= 500
            ? 150.0
            : ((width - 12) / 2).clamp(132.0, 220.0);
        return Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in entries)
                SizedBox(
                  width: tileWidth,
                  height: 164,
                  child: switch (entry) {
                    _UnifiedFolderEntry() => _UnifiedGridFolderTile(
                      entry: entry,
                      summary: folderSummaries.byPath[entry.path]!,
                      expanded: false,
                      onToggle: () => _openDirectory(entry.path),
                      onDelete: widget.onDeleteFolder == null
                          ? null
                          : () => widget.onDeleteFolder?.call(entry.path),
                    ),
                    _UnifiedFileEntry() => _UnifiedGridFileTile(
                      entry: entry,
                      statusLabel: widget.rootView.fileStatusLabel(entry.file),
                      mediaThumbnails: widget.mediaThumbnails,
                      remoteFileThumbnails: widget.remoteFileThumbnails,
                      onPreview:
                          entry.file.canPreview && widget.onPreviewFile != null
                          ? () => widget.onPreviewFile?.call(entry.file)
                          : null,
                      onDownload:
                          entry.file.canDownload &&
                              widget.onDownloadFile != null
                          ? () => widget.onDownloadFile?.call(entry.file)
                          : null,
                      onDelete: widget.onDeleteFile == null
                          ? null
                          : () => widget.onDeleteFile?.call(entry.file),
                      onDetails: widget.onShowFileDetails == null
                          ? () => _showFileProperties(entry.file)
                          : () => widget.onShowFileDetails!.call(entry.file),
                    ),
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _FileViewMode { list, details, grid }

enum _FileSortMode { name, updated, size, status }

_FileViewMode _fileViewModeFromName(String name) {
  return _FileViewMode.values.firstWhere(
    (mode) => mode.name == name,
    orElse: () => _FileViewMode.list,
  );
}

_FileSortMode _fileSortModeFromName(String name) {
  return _FileSortMode.values.firstWhere(
    (mode) => mode.name == name,
    orElse: () => _FileSortMode.name,
  );
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
}

class _FileTreeToolbar extends StatelessWidget {
  final _FileViewMode viewMode;
  final _FileSortMode sortMode;
  final bool sortAscending;
  final int itemCount;
  final int totalFileCount;
  final ValueChanged<_FileViewMode> onViewModeChanged;
  final ValueChanged<_FileSortMode> onSortModeChanged;
  final VoidCallback onSortDirectionChanged;

  const _FileTreeToolbar({
    required this.viewMode,
    required this.sortMode,
    required this.sortAscending,
    required this.itemCount,
    required this.totalFileCount,
    required this.onViewModeChanged,
    required this.onSortModeChanged,
    required this.onSortDirectionChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 700;
        final controls = <Widget>[
          _buildViewSelector(compact: compact),
          PopupMenuButton<_FileSortMode>(
            key: const ValueKey('file_tree_sort_button'),
            tooltip: '选择排序字段',
            icon: const Icon(Icons.sort),
            onSelected: onSortModeChanged,
            itemBuilder: (context) => [
              _sortItem(_FileSortMode.name, '名称', Icons.sort_by_alpha),
              _sortItem(_FileSortMode.updated, '修改时间', Icons.schedule_outlined),
              _sortItem(_FileSortMode.size, '大小', Icons.data_usage),
              _sortItem(_FileSortMode.status, '同步状态', Icons.sync),
            ],
          ),
          IconButton(
            key: const ValueKey('file_tree_sort_direction_button'),
            tooltip: sortAscending ? '当前升序，点击切换为降序' : '当前降序，点击切换为升序',
            onPressed: onSortDirectionChanged,
            icon: Icon(
              sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
            ),
          ),
        ];
        final count = Text(
          '当前 $itemCount 项 · 共 $totalFileCount 个文件',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.bodySmall,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: [
              ...controls,
              const SizedBox(width: 4),
              Expanded(child: count),
            ],
          ),
        );
      },
    );
  }

  Widget _buildViewSelector({required bool compact}) {
    return SegmentedButton<_FileViewMode>(
      key: const ValueKey('file_tree_view_mode_button'),
      segments: [
        ButtonSegment(
          value: _FileViewMode.list,
          icon: const Icon(Icons.view_list_outlined),
          label: compact ? null : const Text('列表'),
          tooltip: '列表视图',
        ),
        ButtonSegment(
          value: _FileViewMode.details,
          icon: const Icon(Icons.view_agenda_outlined),
          label: compact ? null : const Text('详细'),
          tooltip: '详细视图',
        ),
        ButtonSegment(
          value: _FileViewMode.grid,
          icon: const Icon(Icons.grid_view_outlined),
          label: compact ? null : const Text('图标'),
          tooltip: '图标视图',
        ),
      ],
      selected: {viewMode},
      showSelectedIcon: false,
      onSelectionChanged: (selection) {
        onViewModeChanged(selection.first);
      },
    );
  }

  PopupMenuItem<_FileSortMode> _sortItem(
    _FileSortMode value,
    String label,
    IconData icon,
  ) {
    return PopupMenuItem(
      value: value,
      child: ListTile(
        dense: true,
        leading: Icon(icon),
        title: Text(label),
        trailing: sortMode == value ? const Icon(Icons.check, size: 18) : null,
      ),
    );
  }
}

class _DirectoryBreadcrumbs extends StatelessWidget {
  final String rootName;
  final String currentPath;
  final VoidCallback onRoot;
  final VoidCallback onUp;
  final ValueChanged<String> onSegment;

  const _DirectoryBreadcrumbs({
    required this.rootName,
    required this.currentPath,
    required this.onRoot,
    required this.onUp,
    required this.onSegment,
  });

  @override
  Widget build(BuildContext context) {
    final parts = _pathParts(currentPath);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            if (parts.isNotEmpty)
              IconButton(
                key: const ValueKey('file_tree_up_button'),
                tooltip: '返回上级目录',
                onPressed: onUp,
                icon: const Icon(Icons.arrow_upward),
              ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    TextButton(
                      key: const ValueKey('file_tree_breadcrumb_root'),
                      onPressed: onRoot,
                      child: Text(
                        rootName.trim().isEmpty ? '根目录' : rootName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (var index = 0; index < parts.length; index += 1) ...[
                      const Icon(Icons.chevron_right, size: 18),
                      TextButton(
                        onPressed: () =>
                            onSegment(parts.take(index + 1).join('/')),
                        child: Text(parts[index]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailsHeader extends StatelessWidget {
  final _FileSortMode sortMode;
  final bool sortAscending;
  final ValueChanged<_FileSortMode> onSortModeChanged;

  const _DetailsHeader({
    required this.sortMode,
    required this.sortAscending,
    required this.onSortModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              const SizedBox(width: 28),
              Expanded(
                child: _SortableHeaderLabel(
                  label: '名称',
                  mode: _FileSortMode.name,
                  selectedMode: sortMode,
                  ascending: sortAscending,
                  onSelected: onSortModeChanged,
                ),
              ),
              if (!narrow) ...[
                SizedBox(
                  width: 86,
                  child: _SortableHeaderLabel(
                    label: '大小',
                    mode: _FileSortMode.size,
                    selectedMode: sortMode,
                    ascending: sortAscending,
                    onSelected: onSortModeChanged,
                  ),
                ),
                SizedBox(
                  width: 148,
                  child: _SortableHeaderLabel(
                    label: '修改时间',
                    mode: _FileSortMode.updated,
                    selectedMode: sortMode,
                    ascending: sortAscending,
                    onSelected: onSortModeChanged,
                  ),
                ),
              ],
              SizedBox(
                width: narrow ? 86 : 116,
                child: _SortableHeaderLabel(
                  label: '状态',
                  mode: _FileSortMode.status,
                  selectedMode: sortMode,
                  ascending: sortAscending,
                  onSelected: onSortModeChanged,
                ),
              ),
              const SizedBox(width: 36),
            ],
          ),
        );
      },
    );
  }
}

class _SortableHeaderLabel extends StatelessWidget {
  final String label;
  final _FileSortMode mode;
  final _FileSortMode selectedMode;
  final bool ascending;
  final ValueChanged<_FileSortMode> onSelected;

  const _SortableHeaderLabel({
    required this.label,
    required this.mode,
    required this.selectedMode,
    required this.ascending,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final selected = mode == selectedMode;
    return InkWell(
      onTap: () => onSelected(mode),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 2),
              Icon(
                ascending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 13,
              ),
            ],
          ],
        ),
      ),
    );
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
  final Map<String, List<_UnifiedTreeEntry>> entriesByDirectory;

  const _UnifiedFolderSummaries({
    required this.byPath,
    required this.entriesByDirectory,
  });

  static _UnifiedFolderSummaries fromFiles(
    List<_UnifiedFileRecord> files,
    _SyncRootViewData rootView,
  ) {
    final summaries = <String, _UnifiedFolderSummary>{};
    final childrenByDirectory = <String, Map<String, _UnifiedTreeEntry>>{};
    for (final file in files) {
      final parts = _pathParts(file.path);
      final parentPath = parts.length <= 1
          ? ''
          : parts.take(parts.length - 1).join('/');
      childrenByDirectory.putIfAbsent(
        parentPath,
        () => <String, _UnifiedTreeEntry>{},
      )[file.path] = _UnifiedFileEntry(
        name: parts.last,
        path: file.path,
        depth: 0,
        file: file,
      );
      var path = '';
      for (var index = 0; index < parts.length - 1; index += 1) {
        final parent = path;
        path = path.isEmpty ? parts[index] : '$path/${parts[index]}';
        childrenByDirectory.putIfAbsent(
          parent,
          () => <String, _UnifiedTreeEntry>{},
        )[path] ??= _UnifiedFolderEntry(
          name: parts[index],
          path: path,
          depth: 0,
        );
        final current = summaries[path];
        summaries[path] = (current ?? const _UnifiedFolderSummary()).addFile(
          _folderStatusLabel(rootView.fileStatusLabel(file)),
          file.backup?.sizeBytes ?? file.task?.sizeBytes ?? 0,
          _unifiedFileUpdatedAt(file),
        );
      }
    }
    return _UnifiedFolderSummaries(
      byPath: summaries,
      entriesByDirectory: {
        for (final entry in childrenByDirectory.entries)
          entry.key: entry.value.values.toList(growable: false),
      },
    );
  }

  static Future<_UnifiedFolderSummaries> fromFilesAsync(
    List<_UnifiedFileRecord> files,
    _SyncRootViewData rootView,
  ) async {
    final summaries = <String, _UnifiedFolderSummary>{};
    final childrenByDirectory = <String, Map<String, _UnifiedTreeEntry>>{};
    for (var fileIndex = 0; fileIndex < files.length; fileIndex += 1) {
      final file = files[fileIndex];
      final parts = _pathParts(file.path);
      final parentPath = parts.length <= 1
          ? ''
          : parts.take(parts.length - 1).join('/');
      childrenByDirectory.putIfAbsent(
        parentPath,
        () => <String, _UnifiedTreeEntry>{},
      )[file.path] = _UnifiedFileEntry(
        name: parts.last,
        path: file.path,
        depth: 0,
        file: file,
      );
      var path = '';
      for (var index = 0; index < parts.length - 1; index += 1) {
        final parent = path;
        path = path.isEmpty ? parts[index] : '$path/${parts[index]}';
        childrenByDirectory.putIfAbsent(
          parent,
          () => <String, _UnifiedTreeEntry>{},
        )[path] ??= _UnifiedFolderEntry(
          name: parts[index],
          path: path,
          depth: 0,
        );
        final current = summaries[path];
        summaries[path] = (current ?? const _UnifiedFolderSummary()).addFile(
          _folderStatusLabel(rootView.fileStatusLabel(file)),
          file.backup?.sizeBytes ?? file.task?.sizeBytes ?? 0,
          _unifiedFileUpdatedAt(file),
        );
      }
      // Keep long directory indexes from monopolizing a frame. The next
      // batch resumes on the event loop while the UI remains responsive.
      if (fileIndex > 0 && fileIndex % 96 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return _UnifiedFolderSummaries(
      byPath: summaries,
      entriesByDirectory: {
        for (final entry in childrenByDirectory.entries)
          entry.key: entry.value.values.toList(growable: false),
      },
    );
  }
}

class _UnifiedFolderSummary {
  final int fileCount;
  final int sizeBytes;
  final DateTime? updatedAt;
  final String statusLabel;

  const _UnifiedFolderSummary({
    this.fileCount = 0,
    this.sizeBytes = 0,
    this.updatedAt,
    this.statusLabel = '已同步',
  });

  _UnifiedFolderSummary addFile(
    String nextStatusLabel,
    int nextSizeBytes,
    DateTime nextUpdatedAt,
  ) {
    return _UnifiedFolderSummary(
      fileCount: fileCount + 1,
      sizeBytes: sizeBytes + nextSizeBytes,
      updatedAt: nextUpdatedAt.isAfter(updatedAt ?? _epochDateTime)
          ? nextUpdatedAt
          : updatedAt,
      statusLabel: _dominantFileStatusLabel(statusLabel, nextStatusLabel),
    );
  }
}

class _UnifiedDetailsFolderRow extends StatelessWidget {
  final _UnifiedFolderEntry entry;
  final _UnifiedFolderSummary summary;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onDelete;

  const _UnifiedDetailsFolderRow({
    required this.entry,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.only(
              left: 12 + _treeIndent(entry.depth),
            ),
            leading: Icon(
              expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
              color: colorScheme.primary,
            ),
            onTap: onToggle,
            title: Text(
              _displayFileName(entry.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${summary.fileCount} 个文件 · ${_formatBytes(summary.sizeBytes)} · ${_folderDateText(summary)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _FileStatusIcon(label: summary.statusLabel),
                if (onDelete != null) _FolderActionMenu(onDelete: onDelete),
              ],
            ),
          );
        }
        return InkWell(
          onTap: onToggle,
          child: Padding(
            padding: EdgeInsets.only(
              left: 12 + _treeIndent(entry.depth),
              top: 7,
              bottom: 7,
              right: 4,
            ),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayFileName(entry.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${summary.fileCount} 个文件 · ${entry.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 86,
                  child: Text(
                    _formatBytes(summary.sizeBytes),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SizedBox(
                  width: 148,
                  child: Text(
                    _folderDateText(summary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SizedBox(
                  width: 116,
                  child: _FileStatusIndicator(
                    label: summary.statusLabel,
                    showLabel: true,
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: onDelete == null
                      ? null
                      : _FolderActionMenu(onDelete: onDelete),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _UnifiedDetailsFileRow extends StatelessWidget {
  final _UnifiedFileEntry entry;
  final String statusLabel;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;
  final VoidCallback onDetails;

  const _UnifiedDetailsFileRow({
    required this.entry,
    required this.statusLabel,
    required this.onPreview,
    required this.onDownload,
    required this.onDelete,
    required this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return _UnifiedFileRow(
            entry: entry,
            statusLabel: statusLabel,
            onPreview: onPreview,
            onDownload: onDownload,
            onDelete: onDelete,
            onDetails: onDetails,
            showMetadata: true,
            showTrailingStatus: false,
          );
        }
        final file = entry.file;
        final colorScheme = Theme.of(context).colorScheme;
        return InkWell(
          onTap: onPreview ?? onDetails,
          child: Padding(
            padding: EdgeInsets.only(
              left: 12 + _treeIndent(entry.depth),
              top: 7,
              bottom: 7,
              right: 4,
            ),
            child: Row(
              children: [
                Icon(
                  file.decryptable ? _fileIcon(entry.path) : Icons.lock_outline,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayFileName(entry.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        entry.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 86,
                  child: Text(
                    _fileSizeText(file),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SizedBox(
                  width: 148,
                  child: Text(
                    _fileDateText(file),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SizedBox(
                  width: 116,
                  child: _FileStatusIndicator(
                    label: statusLabel,
                    showLabel: true,
                  ),
                ),
                _FileTreeActionMenu(
                  onPreview: onPreview,
                  onDownload: onDownload,
                  onDelete: onDelete,
                  onDetails: onDetails,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _UnifiedGridFolderTile extends StatelessWidget {
  final _UnifiedFolderEntry entry;
  final _UnifiedFolderSummary summary;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onDelete;

  const _UnifiedGridFolderTile({
    required this.entry,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 96,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: colorScheme.surfaceContainerHighest,
                        child: Center(
                          child: Icon(
                            expanded
                                ? Icons.folder_open_outlined
                                : Icons.folder_outlined,
                            size: 48,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    if (onDelete != null)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: _FolderActionMenu(onDelete: onDelete),
                      ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: _FileStatusIndicator(
                        label: summary.statusLabel,
                        surface: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              Text(
                _displayFileName(entry.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                '${summary.fileCount} 个文件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnifiedGridFileTile extends StatelessWidget {
  final _UnifiedFileEntry entry;
  final String statusLabel;
  final MediaAssetThumbnailGateway? mediaThumbnails;
  final RemoteFileThumbnailGateway? remoteFileThumbnails;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;
  final VoidCallback onDetails;

  const _UnifiedGridFileTile({
    required this.entry,
    required this.statusLabel,
    required this.mediaThumbnails,
    required this.remoteFileThumbnails,
    required this.onPreview,
    required this.onDownload,
    required this.onDelete,
    required this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    final file = entry.file;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: onPreview ?? onDetails,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  _GridFileVisual(
                    file: file,
                    path: entry.path,
                    mediaThumbnails: mediaThumbnails,
                    remoteFileThumbnails: remoteFileThumbnails,
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: _FileTreeActionMenu(
                      onPreview: onPreview,
                      onDownload: onDownload,
                      onDelete: onDelete,
                      onDetails: onDetails,
                    ),
                  ),
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: _FileStatusIndicator(
                      label: statusLabel,
                      surface: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                _displayFileName(entry.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                _fileSizeText(file),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridFileVisual extends StatefulWidget {
  final _UnifiedFileRecord file;
  final String path;
  final MediaAssetThumbnailGateway? mediaThumbnails;
  final RemoteFileThumbnailGateway? remoteFileThumbnails;

  const _GridFileVisual({
    required this.file,
    required this.path,
    required this.mediaThumbnails,
    required this.remoteFileThumbnails,
  });

  @override
  State<_GridFileVisual> createState() => _GridFileVisualState();
}

class _GridFileVisualState extends State<_GridFileVisual> {
  Future<Uint8List?>? _mediaThumbnailFuture;
  Future<Uint8List?>? _remoteThumbnailFuture;

  @override
  void initState() {
    super.initState();
    _mediaThumbnailFuture = _loadMediaThumbnail();
    _remoteThumbnailFuture = _loadRemoteThumbnail();
  }

  @override
  void didUpdateWidget(covariant _GridFileVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldAssetId = oldWidget.file.task?.assetId.trim() ?? '';
    final nextAssetId = widget.file.task?.assetId.trim() ?? '';
    final oldVersionId = oldWidget.file.backup?.versionId ?? '';
    final nextVersionId = widget.file.backup?.versionId ?? '';
    if (oldWidget.path != widget.path ||
        oldAssetId != nextAssetId ||
        oldVersionId != nextVersionId ||
        oldWidget.mediaThumbnails != widget.mediaThumbnails ||
        oldWidget.remoteFileThumbnails != widget.remoteFileThumbnails) {
      _mediaThumbnailFuture = _loadMediaThumbnail();
      _remoteThumbnailFuture = _loadRemoteThumbnail();
    }
  }

  Future<Uint8List?>? _loadMediaThumbnail() {
    final task = widget.file.task;
    final gateway = widget.mediaThumbnails;
    final previewName = widget.file.backup?.name ?? widget.path;
    if (task == null ||
        task.sourceType != 'media_asset' ||
        task.assetId.trim().isEmpty ||
        gateway == null ||
        remoteFilePreviewKindFor(previewName) != RemoteFilePreviewKind.image) {
      return null;
    }
    return gateway.loadThumbnail(task.assetId.trim());
  }

  Future<Uint8List?>? _loadRemoteThumbnail() {
    if (widget.file.localImageThumbnailPath != null ||
        _mediaThumbnailFuture != null) {
      return null;
    }
    final backup = widget.file.backup;
    final gateway = widget.remoteFileThumbnails;
    if (backup == null || gateway == null) {
      return null;
    }
    return gateway.load(backup);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final thumbnailPath = widget.file.localImageThumbnailPath;
    final fallback = ColoredBox(
      key: ValueKey('file_grid_icon_${widget.path}'),
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          widget.file.decryptable ? _fileIcon(widget.path) : Icons.lock_outline,
          size: 44,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
    Widget visual;
    if (thumbnailPath != null) {
      visual = Image.file(
        File(thumbnailPath),
        key: ValueKey('file_grid_thumbnail_${widget.path}'),
        fit: BoxFit.cover,
        cacheWidth: 360,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => fallback,
      );
    } else {
      visual = _FutureThumbnailImage(
        path: widget.path,
        primary: _mediaThumbnailFuture,
        secondary: _remoteThumbnailFuture,
        fallback: fallback,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(width: double.infinity, height: 96, child: visual),
    );
  }
}

class _FutureThumbnailImage extends StatelessWidget {
  final String path;
  final Future<Uint8List?>? primary;
  final Future<Uint8List?>? secondary;
  final Widget fallback;

  const _FutureThumbnailImage({
    required this.path,
    required this.primary,
    required this.secondary,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: primary ?? secondary,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return _MemoryThumbnail(path: path, bytes: bytes);
        }
        if (primary != null && secondary != null) {
          return FutureBuilder<Uint8List?>(
            future: secondary,
            builder: (context, secondarySnapshot) {
              final secondaryBytes = secondarySnapshot.data;
              if (secondaryBytes == null || secondaryBytes.isEmpty) {
                return fallback;
              }
              return _MemoryThumbnail(path: path, bytes: secondaryBytes);
            },
          );
        }
        return fallback;
      },
    );
  }
}

class _MemoryThumbnail extends StatelessWidget {
  final String path;
  final Uint8List bytes;

  const _MemoryThumbnail({required this.path, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      bytes,
      key: ValueKey('file_grid_thumbnail_$path'),
      fit: BoxFit.cover,
      cacheWidth: 360,
      filterQuality: FilterQuality.low,
      errorBuilder: (_, _, _) {
        final colorScheme = Theme.of(context).colorScheme;
        return ColoredBox(
          color: colorScheme.surfaceContainerHighest,
          child: Center(
            child: Icon(
              _fileIcon(path),
              size: 44,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}

class _FolderActionMenu extends StatelessWidget {
  final VoidCallback? onDelete;

  const _FolderActionMenu({required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_FolderTreeAction>(
      tooltip: '文件夹操作',
      onSelected: (action) {
        if (action == _FolderTreeAction.delete) {
          onDelete?.call();
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _FolderTreeAction.delete,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline),
            title: Text('删除服务器备份'),
          ),
        ),
      ],
    );
  }
}

class _FileTreeActionMenu extends StatelessWidget {
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;
  final VoidCallback onDetails;

  const _FileTreeActionMenu({
    required this.onPreview,
    required this.onDownload,
    required this.onDelete,
    required this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_FileTreeAction>(
      tooltip: '文件操作',
      onSelected: (action) {
        switch (action) {
          case _FileTreeAction.details:
            onDetails();
          case _FileTreeAction.preview:
            onPreview?.call();
          case _FileTreeAction.download:
            onDownload?.call();
          case _FileTreeAction.delete:
            onDelete?.call();
        }
      },
      itemBuilder: (context) => [
        if (onPreview != null)
          const PopupMenuItem(
            value: _FileTreeAction.preview,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.visibility_outlined),
              title: Text('在线预览'),
            ),
          ),
        if (onDownload != null)
          const PopupMenuItem(
            value: _FileTreeAction.download,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.download_outlined),
              title: Text('下载到本地'),
            ),
          ),
        const PopupMenuItem(
          value: _FileTreeAction.details,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.info_outline),
            title: Text('详细信息'),
          ),
        ),
        if (onDelete != null)
          const PopupMenuItem(
            value: _FileTreeAction.delete,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline),
              title: Text('删除服务器备份'),
            ),
          ),
      ],
    );
  }
}

String _fileSizeText(_UnifiedFileRecord file) {
  final size = file.backup?.sizeBytes ?? file.task?.sizeBytes;
  return size == null ? '-' : _formatBytes(size);
}

String _fileDateText(_UnifiedFileRecord file) {
  final remote = file.backup?.updatedAt ?? '';
  if (remote.isNotEmpty) {
    final parsed = DateTime.tryParse(remote);
    return parsed == null ? '-' : _formatDateTime(parsed);
  }
  final local = file.task?.modifiedAt;
  return local == null ? '-' : _formatDateTime(local);
}

String _serverDateText(String? value) {
  final parsed = DateTime.tryParse(value?.trim() ?? '');
  return parsed == null ? '-' : _formatDateTime(parsed);
}

String _folderDateText(_UnifiedFolderSummary summary) {
  final updatedAt = summary.updatedAt;
  return updatedAt == null || updatedAt == _epochDateTime
      ? '-'
      : _formatDateTime(updatedAt);
}

class _UnifiedFolderRow extends StatelessWidget {
  final _UnifiedFolderEntry entry;
  final _UnifiedFolderSummary summary;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onDelete;

  const _UnifiedFolderRow({
    required this.entry,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      minLeadingWidth: 44,
      horizontalTitleGap: 8,
      contentPadding: EdgeInsets.only(left: _treeIndent(entry.depth)),
      leading: SizedBox(
        width: 44,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              size: 20,
              color: colorScheme.primary,
            ),
            Icon(Icons.folder_outlined, size: 22, color: colorScheme.primary),
          ],
        ),
      ),
      onTap: onToggle,
      title: Text(
        _displayFileName(entry.name),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FileStatusIcon(label: summary.statusLabel),
          if (onDelete != null) _FolderActionMenu(onDelete: onDelete),
        ],
      ),
    );
  }
}

class _UnifiedFileRow extends StatelessWidget {
  final _UnifiedFileEntry entry;
  final String statusLabel;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;
  final VoidCallback onDetails;
  final bool showMetadata;
  final bool showTrailingStatus;

  const _UnifiedFileRow({
    required this.entry,
    required this.statusLabel,
    required this.onPreview,
    required this.onDownload,
    required this.onDelete,
    required this.onDetails,
    this.showMetadata = false,
    this.showTrailingStatus = true,
  });

  @override
  Widget build(BuildContext context) {
    final file = entry.file;
    final details = file.detailsSubtitle;
    return ListTile(
      dense: true,
      minLeadingWidth: 24,
      horizontalTitleGap: 8,
      contentPadding: EdgeInsets.only(left: _treeIndent(entry.depth)),
      leading: Icon(
        file.decryptable ? _fileIcon(entry.path) : Icons.lock_outline,
        size: 22,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onTap: onPreview ?? onDetails,
      title: Text(
        _displayFileName(entry.name),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: showMetadata
          ? _FileTreeSubtitle(details: details, statusLabel: statusLabel)
          : null,
      isThreeLine: showMetadata && details.isNotEmpty,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTrailingStatus) _FileStatusIcon(label: statusLabel),
          _FileTreeActionMenu(
            onPreview: onPreview,
            onDownload: onDownload,
            onDelete: onDelete,
            onDetails: onDetails,
          ),
        ],
      ),
    );
  }
}

class _FileStatusIcon extends StatelessWidget {
  final String label;

  const _FileStatusIcon({required this.label});

  @override
  Widget build(BuildContext context) {
    return _FileStatusIndicator(label: label);
  }
}

enum _FileStatusTone { success, info, pending, error }

class _FileStatusPresentation {
  final String label;
  final String shortLabel;
  final IconData icon;
  final _FileStatusTone tone;

  const _FileStatusPresentation({
    required this.label,
    required this.shortLabel,
    required this.icon,
    required this.tone,
  });
}

class _FileStatusIndicator extends StatelessWidget {
  final String label;
  final bool showLabel;
  final bool surface;

  const _FileStatusIndicator({
    required this.label,
    this.showLabel = false,
    this.surface = false,
  });

  @override
  Widget build(BuildContext context) {
    final presentation = _fileStatusPresentation(label);
    final colorScheme = Theme.of(context).colorScheme;
    final color = _fileStatusToneColor(colorScheme, presentation.tone);
    Widget content = SizedBox(
      height: 32,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 32,
            child: Icon(presentation.icon, size: 18, color: color),
          ),
          if (showLabel)
            Flexible(
              child: Text(
                presentation.shortLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
        ],
      ),
    );
    if (surface) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: content,
      );
    }
    return Tooltip(
      message: presentation.label,
      child: Semantics(
        button: true,
        label: presentation.label,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            final messenger = ScaffoldMessenger.maybeOf(context);
            messenger
              ?..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(presentation.label),
                  duration: const Duration(seconds: 2),
                ),
              );
          },
          child: content,
        ),
      ),
    );
  }
}

class _FilePropertiesDialog extends StatelessWidget {
  final _UnifiedFileRecord file;
  final _SyncRootViewData rootView;
  final String statusLabel;

  const _FilePropertiesDialog({
    required this.file,
    required this.rootView,
    required this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    final task = file.task;
    final backup = file.backup;
    final fileName = _pathParts(file.path).last;
    final size = backup?.sizeBytes ?? task?.sizeBytes;
    final uploadedBytes = task?.uploadedBytes ?? 0;
    final uploadTotal = task?.uploadTotalSize ?? task?.sizeBytes ?? 0;
    final mediaSize = MediaQuery.sizeOf(context);
    return AlertDialog(
      key: const ValueKey('file_properties_dialog'),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 12, 10),
      title: Row(
        children: [
          Icon(
            file.decryptable ? _fileIcon(file.path) : Icons.lock_outline,
            size: 34,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(
                  _fileTypeText(fileName),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: math.min(680, math.max(280, mediaSize.width - 72)),
        height: math.min(600, mediaSize.height * 0.68),
        child: ListView(
          key: const ValueKey('file_properties_list'),
          children: [
            _FilePropertySection(
              title: '常规',
              rows: [
                _FilePropertyData('名称', fileName),
                _FilePropertyData('相对路径', file.path),
                _FilePropertyData(
                  '所在目录',
                  _parentPath(file.path).isEmpty
                      ? '根目录'
                      : _parentPath(file.path),
                ),
                _FilePropertyData(
                  '大小',
                  size == null ? '-' : '${_formatBytes(size)} ($size 字节)',
                ),
                _FilePropertyData('修改时间', _fileDateText(file)),
                _FilePropertyData('本地路径', task?.localPath ?? '-'),
              ],
            ),
            _FilePropertySection(
              title: '同步状态',
              rows: [
                _FilePropertyData('当前状态', statusLabel),
                _FilePropertyData('服务器备份', backup == null ? '无' : '有'),
                _FilePropertyData(
                  '清理策略',
                  _cleanupPolicyLabel(rootView.root.cleanupPolicy),
                ),
                _FilePropertyData('本地任务状态', task?.status ?? '-'),
                _FilePropertyData(
                  '上传进度',
                  _uploadProgressText(uploadedBytes, uploadTotal),
                ),
                _FilePropertyData('尝试次数', task?.attempts.toString() ?? '-'),
                _FilePropertyData('最后错误', _notEmpty(task?.lastError)),
              ],
            ),
            _FilePropertySection(
              title: '来源与保护',
              rows: [
                _FilePropertyData('来源类型', _sourceTypeText(task?.sourceType)),
                _FilePropertyData('媒体类型', _notEmpty(task?.assetMediaType)),
                _FilePropertyData('媒体资源 ID', _notEmpty(task?.assetId)),
                _FilePropertyData(
                  '客户端加密',
                  task == null ? '-' : (task.encryptionEnabled ? '已启用' : '未启用'),
                ),
                _FilePropertyData(
                  '远端可解密',
                  backup == null ? '-' : (backup.decryptable ? '是' : '否'),
                ),
              ],
            ),
            _FilePropertySection(
              title: '服务器信息',
              rows: [
                _FilePropertyData('设备 ID', rootView.root.deviceId),
                _FilePropertyData('同步目录 ID', rootView.root.id),
                _FilePropertyData('对象 ID', backup?.objectId ?? '-'),
                _FilePropertyData('版本 ID', backup?.versionId ?? '-'),
                _FilePropertyData(
                  '服务器更新时间',
                  _serverDateText(backup?.updatedAt),
                ),
                _FilePropertyData('内容哈希', _notEmpty(backup?.clientContentHash)),
                _FilePropertyData('远端对象名', _notEmpty(backup?.encryptedName)),
              ],
            ),
            _FilePropertySection(
              title: '任务信息',
              rows: [
                _FilePropertyData('任务 ID', task?.id ?? '-'),
                _FilePropertyData(
                  '创建时间',
                  task == null ? '-' : _formatDateTime(task.createdAt),
                ),
                _FilePropertyData('上传会话 ID', _notEmpty(task?.uploadSessionId)),
                _FilePropertyData('上传载荷哈希', _notEmpty(task?.uploadPayloadHash)),
                _FilePropertyData('分片大小', _byteDetail(task?.uploadChunkSize)),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  String _notEmpty(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? '-' : normalized;
  }

  String _byteDetail(int? value) {
    if (value == null || value <= 0) {
      return '-';
    }
    return '${_formatBytes(value)} ($value 字节)';
  }

  String _uploadProgressText(int uploadedBytes, int totalBytes) {
    if (totalBytes <= 0) {
      return '-';
    }
    final percent = (uploadedBytes * 100 / totalBytes)
        .clamp(0, 100)
        .toStringAsFixed(0);
    return '$percent% (${_formatBytes(uploadedBytes)} / ${_formatBytes(totalBytes)})';
  }

  String _sourceTypeText(String? sourceType) {
    return switch (sourceType) {
      'file' => '本地文件',
      'media_asset' => '系统相册资源',
      'wechat_file' => '微信文件',
      'wechat' => '微信文件',
      'wechat_archive_file' => '微信完整归档',
      'wechat_archive' => '微信完整归档',
      null || '' => '-',
      _ => sourceType,
    };
  }

  String _parentPath(String path) {
    final parts = _pathParts(path);
    return parts.length <= 1 ? '' : parts.take(parts.length - 1).join('/');
  }

  String _fileTypeText(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex <= 0 || dotIndex == fileName.length - 1) {
      return '文件';
    }
    return '${fileName.substring(dotIndex + 1).toUpperCase()} 文件';
  }
}

class _FilePropertySection extends StatelessWidget {
  final String title;
  final List<_FilePropertyData> rows;

  const _FilePropertySection({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                for (var index = 0; index < rows.length; index += 1) ...[
                  _FilePropertyRow(data: rows[index]),
                  if (index < rows.length - 1)
                    Divider(height: 1, color: colorScheme.outlineVariant),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilePropertyRow extends StatelessWidget {
  final _FilePropertyData data;

  const _FilePropertyRow({required this.data});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              data.label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(data.value)),
        ],
      ),
    );
  }
}

class _FilePropertyData {
  final String label;
  final String value;

  const _FilePropertyData(this.label, this.value);
}

class _FileTreeSubtitle extends StatelessWidget {
  final String details;
  final String statusLabel;

  const _FileTreeSubtitle({required this.details, required this.statusLabel});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (details.isNotEmpty)
          Text(
            details,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall,
          ),
        _FileStatusIndicator(label: statusLabel, showLabel: true),
      ],
    );
  }
}

enum _FileTreeAction { details, preview, download, delete }

enum _FolderTreeAction { delete }

class _EmptyFileHint extends StatelessWidget {
  final String? message;

  const _EmptyFileHint({this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message ?? '还没有文件记录，点击顶部扫描按钮生成同步任务。')),
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
  final List<LocalSyncOperationStatus> operations;
  final String currentDeviceId;
  final String currentDeviceName;

  _SyncRootViewData({
    required this.root,
    required this.mapping,
    required this.tasks,
    required this.issues,
    required this.remoteBackups,
    this.operations = const [],
    required this.currentDeviceId,
    required this.currentDeviceName,
  });

  String get displayName {
    if (isMediaBackupRoot) {
      return '相册备份';
    }
    if (isWechatBackupRoot) {
      return mapping?.sourceType == 'wechat_archive' ? '微信电脑完整归档' : '微信文件备份';
    }
    final localPath = mapping?.localPath.trim() ?? '';
    if (localPath.isNotEmpty) {
      final normalized = localPath.replaceAll('\\', '/');
      final segments = normalized.split('/').where((part) => part.isNotEmpty);
      return segments.isEmpty ? localPath : segments.last;
    }
    final knownName = _knownDirectoryNameForEncryptedPath(root.encryptedPath);
    if (knownName != null) {
      return knownName;
    }
    if (!isCurrentDeviceRoot) {
      return '同步目录 $shortRootId';
    }
    return '未绑定目录 $shortRootId';
  }

  String get shortRootId {
    return root.id.length <= 8 ? root.id : root.id.substring(0, 8);
  }

  String get shortDeviceId {
    return root.deviceId.length <= 8
        ? root.deviceId
        : root.deviceId.substring(0, 8);
  }

  bool get isCurrentDeviceRoot {
    return currentDeviceId.isNotEmpty && root.deviceId == currentDeviceId;
  }

  bool get canRunLocalSync {
    return isCurrentDeviceRoot;
  }

  bool get canBindLocalPath {
    if (!isCurrentDeviceRoot || isMediaBackupRoot) {
      return false;
    }
    return mapping == null || mapping!.localPath.trim().isEmpty;
  }

  String get deviceDisplayName {
    final localDeviceName = currentDeviceName.trim();
    if (isCurrentDeviceRoot && localDeviceName.isNotEmpty) {
      return localDeviceName;
    }
    final serverDeviceName = root.deviceName.trim();
    if (serverDeviceName.isNotEmpty) {
      return serverDeviceName;
    }
    return '设备 $shortDeviceId';
  }

  String get deviceLine {
    final scope = isCurrentDeviceRoot ? '当前设备' : '其他设备';
    return '$scope：$deviceDisplayName';
  }

  bool get isUnbound {
    return !isMediaBackupRoot &&
        !isWechatBackupRoot &&
        (mapping == null || mapping!.localPath.trim().isEmpty);
  }

  bool get isWechatBackupRoot {
    return root.encryptedPath.startsWith('wechat-backup:v1:') ||
        _isWechatBackupSource(mapping?.sourceType ?? '');
  }

  bool get isMediaBackupRoot {
    return root.encryptedPath.startsWith('media-backup:v1:') ||
        (mapping?.encryptedPath.startsWith('media-backup:v1:') ?? false);
  }

  String get subtitle {
    if (isMediaBackupRoot) {
      return '手机相册照片和视频';
    }
    if (isWechatBackupRoot) {
      final localPath = mapping?.localPath.trim() ?? '';
      return localPath.isEmpty ? '本机未绑定微信目录' : localPath;
    }
    if (!isUnbound) {
      return mapping!.localPath;
    }
    if (!isCurrentDeviceRoot) {
      return '其他设备目录，仅可查看';
    }
    return '本机未绑定路径，可在目录操作中重新绑定';
  }

  int get backedUpDeletedLocalCount {
    return tasks.where((task) => task.status == 'deleted_local').length;
  }

  int get pendingTaskCount {
    return tasks.where((task) => task.status == 'pending').length;
  }

  int get waitingStableTaskCount {
    return tasks.where((task) => task.status == 'waiting_stable').length;
  }

  int get failedTaskCount {
    return tasks.where((task) => task.status == 'failed').length;
  }

  bool get shouldShowDeletePolicyNotice {
    return root.cleanupPolicy == 'delete' && backedUpDeletedLocalCount > 0;
  }

  late final List<_UnifiedFileRecord> fileEntries = _buildFileEntries();

  List<_UnifiedFileRecord> _buildFileEntries() {
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
      final uploadedBytes = task?.uploadedBytes ?? 0;
      final totalBytes = task?.uploadTotalSize ?? 0;
      if (uploadedBytes > 0 && totalBytes > 0) {
        final percent = (uploadedBytes * 100 / totalBytes).floor().clamp(1, 99);
        return '待续传 $percent%';
      }
      return '待上传';
    }
    if (task?.status == 'waiting_stable') {
      return '等待写入完成';
    }
    if (task?.status == 'failed') {
      return '上传失败';
    }
    if (task?.status == 'cleanup_pending') {
      return '待清理';
    }
    if (task != null && _taskNeedsLocalCleanup(task, root.cleanupPolicy)) {
      return '服务器已备份，待删除本地';
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
    if (isWechatBackupRoot && canBindLocalPath) {
      return '待绑定';
    }
    if (issues.isNotEmpty) {
      return '待处理';
    }
    if (tasks.any((task) => task.status == 'failed')) {
      return '上传失败';
    }
    if (tasks.any((task) => task.status == 'pending')) {
      return '待上传';
    }
    if (tasks.any((task) => task.status == 'waiting_stable')) {
      return '等待写入完成';
    }
    if (tasks.any((task) => _taskNeedsLocalCleanup(task, root.cleanupPolicy))) {
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

  bool get canPreview {
    final remoteBackup = backup;
    return remoteBackup != null && remoteFileCanAttemptPreview(remoteBackup);
  }

  bool get canDownload {
    final remoteBackup = backup;
    return remoteBackup != null &&
        remoteBackup.decryptable &&
        remoteBackup.encryptedName.isNotEmpty &&
        remoteBackup.metadataJson.isNotEmpty;
  }

  String? get localImageThumbnailPath {
    final localTask = task;
    final previewName = backup?.name ?? path;
    if (localTask == null ||
        localTask.sourceType != 'file' ||
        localTask.localPath.trim().isEmpty ||
        localTask.status == 'deleted_local' ||
        remoteFilePreviewKindFor(previewName) != RemoteFilePreviewKind.image) {
      return null;
    }
    return localTask.localPath;
  }

  String get detailsSubtitle {
    final size = backup?.sizeBytes ?? task?.sizeBytes;
    final parts = <String>[];
    if (size != null) {
      parts.add(_formatBytes(size));
    }
    final dateText = _fileDateText(this);
    if (dateText != '-') {
      parts.add(dateText);
    }
    final error = task?.lastError.trim() ?? '';
    if (task?.status == 'failed' && error.isNotEmpty) {
      parts.add(error);
    }
    return parts.join(' · ');
  }
}

double _treeIndent(int depth) {
  return depth.clamp(0, 4).toDouble() * 12;
}

_FileStatusPresentation _fileStatusPresentation(String label) {
  if (label.startsWith('待续传 ')) {
    return _FileStatusPresentation(
      label: label,
      shortLabel: label,
      icon: Icons.cloud_upload_outlined,
      tone: _FileStatusTone.pending,
    );
  }
  return switch (label) {
    '上传失败' => const _FileStatusPresentation(
      label: '上传失败',
      shortLabel: '上传失败',
      icon: Icons.error_outline,
      tone: _FileStatusTone.error,
    ),
    '无法解密' => const _FileStatusPresentation(
      label: '无法解密',
      shortLabel: '无法解密',
      icon: Icons.lock_outline,
      tone: _FileStatusTone.error,
    ),
    '待上传' || '待续传' => _FileStatusPresentation(
      label: label,
      shortLabel: label,
      icon: Icons.cloud_upload_outlined,
      tone: _FileStatusTone.pending,
    ),
    '等待写入完成' => const _FileStatusPresentation(
      label: '等待写入完成',
      shortLabel: '等待写入',
      icon: Icons.hourglass_top_outlined,
      tone: _FileStatusTone.pending,
    ),
    '待清理' || '服务器已备份，待删除本地' => _FileStatusPresentation(
      label: label,
      shortLabel: '待清理',
      icon: Icons.cleaning_services_outlined,
      tone: _FileStatusTone.pending,
    ),
    '待确认' || '已上传，服务器待确认' => _FileStatusPresentation(
      label: label,
      shortLabel: '待确认',
      icon: Icons.cloud_sync_outlined,
      tone: _FileStatusTone.info,
    ),
    '服务器已备份，本地已删除' || '服务器已备份，本机未下载' => _FileStatusPresentation(
      label: label,
      shortLabel: '仅云端',
      icon: Icons.cloud_outlined,
      tone: _FileStatusTone.info,
    ),
    '已清理' => const _FileStatusPresentation(
      label: '已清理',
      shortLabel: '已清理',
      icon: Icons.cloud_outlined,
      tone: _FileStatusTone.info,
    ),
    '服务器已备份' ||
    '服务器已备份，本地保留' ||
    '已备份' ||
    '已上传' ||
    '已归档' ||
    '已同步' => _FileStatusPresentation(
      label: label,
      shortLabel: label == '服务器已备份，本地保留' ? '已备份' : label,
      icon: Icons.cloud_done_outlined,
      tone: _FileStatusTone.success,
    ),
    _ => _FileStatusPresentation(
      label: label.isEmpty ? '状态未知' : label,
      shortLabel: label.isEmpty ? '未知' : label,
      icon: Icons.info_outline,
      tone: _FileStatusTone.info,
    ),
  };
}

Color _fileStatusToneColor(ColorScheme colorScheme, _FileStatusTone tone) {
  return switch (tone) {
    _FileStatusTone.success => colorScheme.primary,
    _FileStatusTone.info => colorScheme.secondary,
    _FileStatusTone.pending => colorScheme.tertiary,
    _FileStatusTone.error => colorScheme.error,
  };
}

String _cleanupPolicyLabel(String policy) {
  return switch (policy) {
    'keep' => '保留本地',
    'delete' => '上传后删除',
    'archive' => '上传后归档',
    _ => policy,
  };
}

bool _isAndroidDownloadsPath(String localPath) {
  final normalized = localPath.trim().replaceAll('\\', '/').toLowerCase();
  return normalized == '/storage/emulated/0/download' ||
      normalized == '/sdcard/download';
}

String? _knownDirectoryNameForEncryptedPath(String encryptedPath) {
  if (encryptedPath ==
      const Sha256LocalPathProtector().protectLocalPath(
        _androidDownloadsPath,
      )) {
    return 'Download';
  }
  return null;
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
    'waiting_stable' => '等待写入完成',
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

bool _taskNeedsLocalCleanup(LocalUploadTask task, String cleanupPolicy) {
  return task.status == 'cleanup_pending' ||
      (cleanupPolicy == 'delete' && task.status == 'clean');
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
  if (status.startsWith('待续传 ')) {
    return 70;
  }
  return switch (status) {
    '无法解密' => 80,
    '上传失败' => 75,
    '待上传' => 70,
    '等待写入完成' => 65,
    '待清理' => 60,
    '服务器已备份，待删除本地' => 60,
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
  if (fileStatusLabel.startsWith('待续传 ')) {
    return '待续传';
  }
  return switch (fileStatusLabel) {
    '无法解密' => '无法解密',
    '上传失败' => '上传失败',
    '待上传' => '待上传',
    '等待写入完成' => '等待写入',
    '待清理' => '待清理',
    '服务器已备份，待删除本地' => '待清理',
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

String _displayFileName(String name) {
  return name.contains('\uFFFD') ? '名称编码异常' : name;
}

DateTime _unifiedFileUpdatedAt(_UnifiedFileRecord file) {
  final remoteDate = file.backup?.updatedAt ?? '';
  final parsedRemote = DateTime.tryParse(remoteDate);
  if (parsedRemote != null) {
    return parsedRemote;
  }
  return file.task?.modifiedAt ?? _epochDateTime;
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
  final WechatFolderDiscoveryGateway wechatFolderDiscovery;
  final LocalPathProtector pathProtector;
  final String devicePlatform;
  final bool showAndroidFileAccessGuide;
  final bool wechatOnly;
  final LocalSyncRootMapping? existingMapping;

  const _CreateSyncRootDialog({
    required this.folderPicker,
    required this.fileAccessPermission,
    required this.wechatFolderDiscovery,
    required this.pathProtector,
    required this.devicePlatform,
    required this.showAndroidFileAccessGuide,
    this.wechatOnly = false,
    this.existingMapping,
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
  bool _encryptionEnabled = true;
  final Set<String> _includedTypes = {'image', 'video', 'document'};
  String _wechatMode = 'archive';
  String? _folderErrorMessage;
  String? _permissionStatusMessage;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingMapping;
    if (existing == null) {
      return;
    }
    _localPathController.text = existing.localPath;
    _encryptedPathController.text = existing.encryptedPath;
    _encryptionEnabled = existing.encryptionEnabled;
    _cleanupPolicy = widget.wechatOnly ? 'keep' : existing.cleanupPolicy;
    if (existing.sourceType == 'wechat') {
      _wechatMode = 'files';
    } else if (existing.sourceType == 'wechat_archive') {
      _wechatMode = 'archive';
    }
    final types = existing.includedFileTypes
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    if (types.isNotEmpty) {
      _includedTypes
        ..clear()
        ..addAll(types);
    }
  }

  void _toggleIncludedType(String type, bool enabled) {
    if (enabled) {
      _includedTypes.add(type);
    } else if (_includedTypes.length > 1) {
      _includedTypes.remove(type);
    }
    setState(() {});
  }

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

  Future<void> _detectWechatFolder() async {
    if (widget.devicePlatform == 'android' &&
        !await widget.fileAccessPermission.hasFileAccessPermission()) {
      await _openFileAccessSettings();
      if (!mounted ||
          !await widget.fileAccessPermission.hasFileAccessPermission()) {
        return;
      }
    }
    final result = await widget.wechatFolderDiscovery.discover(
      widget.devicePlatform,
    );
    if (!mounted) {
      return;
    }
    if (result == null) {
      setState(() {
        _permissionStatusMessage = null;
        _folderErrorMessage = widget.devicePlatform == 'android'
            ? '未找到系统允许访问的微信目录。Pixel 等原生 Android 通常只能自动读取微信保存到系统相册或公开目录的文件。'
            : '未找到常见微信目录，请手动选择微信的文件存储目录。';
      });
      return;
    }
    _setSelectedLocalPath(result.path);
    setState(() {
      _permissionStatusMessage = result.isPrivateAppDirectory
          ? '系统允许读取微信应用目录，将自动监控其中可访问的文件。'
          : widget.devicePlatform == 'android'
          ? '已找到微信公开文件目录；微信私有目录中的文档可能仍受系统限制。'
          : '已找到微信文件目录，将自动监控新增文件。';
    });
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
        _permissionStatusMessage = '已打开系统授权页。授权完成后请返回 VaultSync 继续操作。';
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
      title: Text(
        widget.wechatOnly
            ? widget.existingMapping == null
                  ? widget.showAndroidFileAccessGuide
                        ? '新增微信文件备份'
                        : '新增微信电脑备份'
                  : widget.showAndroidFileAccessGuide
                  ? '微信文件备份设置'
                  : '微信电脑备份设置'
            : '新增同步目录',
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.wechatOnly) ...[
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('电脑端可自动归档微信数据；Android 仍只备份可访问的微信文件。'),
                ),
                const SizedBox(height: 8),
                if (widget.showAndroidFileAccessGuide)
                  _buildAndroidWechatPathOptions(context)
                else
                  _buildDesktopLocalPathPicker(),
                const SizedBox(height: 8),
                if (!widget.showAndroidFileAccessGuide) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('备份范围'),
                  ),
                  RadioGroup<String>(
                    groupValue: _wechatMode,
                    onChanged: (value) {
                      setState(() {
                        _wechatMode = value ?? 'archive';
                      });
                    },
                    child: Column(
                      children: [
                        RadioListTile<String>(
                          key: const ValueKey('wechat_archive_mode_option'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: 'archive',
                          title: const Text('完整数据归档'),
                          subtitle: const Text(
                            '包含微信数据库、图片、视频、语音和文件；数据库保持原始加密格式，首次归档可能较大',
                          ),
                        ),
                        RadioListTile<String>(
                          key: const ValueKey('wechat_files_mode_option'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: 'files',
                          title: const Text('仅备份微信文件'),
                          subtitle: const Text('只上传图片、视频和文档，不包含数据库'),
                        ),
                      ],
                    ),
                  ),
                ] else
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('备份类型'),
                  ),
                if (widget.showAndroidFileAccessGuide ||
                    _wechatMode == 'files') ...[
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('图片'),
                    value: _includedTypes.contains('image'),
                    onChanged: (value) =>
                        _toggleIncludedType('image', value == true),
                  ),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('视频'),
                    value: _includedTypes.contains('video'),
                    onChanged: (value) =>
                        _toggleIncludedType('video', value == true),
                  ),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('文档'),
                    value: _includedTypes.contains('document'),
                    onChanged: (value) =>
                        _toggleIncludedType('document', value == true),
                  ),
                ],
              ] else if (widget.showAndroidFileAccessGuide)
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
              if (!widget.wechatOnly) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('sync_root_encrypted_path_field'),
                  controller: _encryptedPathController,
                  decoration: const InputDecoration(labelText: '服务器路径标识'),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return '请输入服务器路径标识';
                    }
                    return null;
                  },
                ),
              ],
              const SizedBox(height: 12),
              SwitchListTile(
                key: const ValueKey('sync_root_encryption_enabled_field'),
                contentPadding: EdgeInsets.zero,
                value: _encryptionEnabled,
                title: const Text('服务器端加密存储'),
                subtitle: Text(
                  widget.existingMapping != null
                      ? '已有备份的存储方式不能直接修改'
                      : _encryptionEnabled
                      ? '上传前在本机加密，服务器只保存密文'
                      : '服务器保存原文件内容，便于在 NAS 上直接查看',
                ),
                onChanged: widget.existingMapping != null
                    ? null
                    : (value) {
                        setState(() {
                          _encryptionEnabled = value;
                        });
                      },
              ),
              const SizedBox(height: 12),
              if (widget.wechatOnly)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.shield_outlined),
                  title: Text('保留微信本地文件'),
                  subtitle: Text('备份不会删除或修改微信正在使用的文件'),
                )
              else
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
          child: Text(widget.existingMapping == null ? '保存' : '更新配置'),
        ),
      ],
    );
  }

  Widget _buildDesktopLocalPathPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: const ValueKey('sync_root_local_path_field'),
                controller: _localPathController,
                readOnly: true,
                decoration: const InputDecoration(labelText: '本地目录'),
                validator: widget.wechatOnly
                    ? (value) {
                        if (value == null || value.trim().isEmpty) {
                          return '请先自动查找或手动选择微信目录';
                        }
                        return null;
                      }
                    : null,
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
        ),
        if (widget.wechatOnly)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('detect_wechat_folder_button'),
              onPressed: _detectWechatFolder,
              icon: const Icon(Icons.manage_search_outlined),
              label: const Text('自动查找微信目录'),
            ),
          ),
      ],
    );
  }

  Widget _buildAndroidWechatPathOptions(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const ValueKey('detect_wechat_folder_button'),
          onPressed: _detectWechatFolder,
          icon: const Icon(Icons.manage_search_outlined),
          label: const Text('授权并自动查找'),
        ),
        const SizedBox(height: 4),
        Text(
          '优先检测系统允许访问的微信目录。原生 Android 不开放微信私有目录时，仍可备份微信保存到系统相册或公开目录的文件。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('choose_sync_folder_button'),
            onPressed: _chooseFolder,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('手动选择可访问目录'),
          ),
        ),
        TextFormField(
          key: const ValueKey('sync_root_local_path_field'),
          controller: _localPathController,
          readOnly: true,
          decoration: const InputDecoration(labelText: '微信文件目录'),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return '请先自动查找或手动选择微信目录';
            }
            return null;
          },
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
        _PathChoiceTile(
          key: const ValueKey('use_downloads_path_button'),
          selected: groupValue == _androidDownloadsPath,
          onTap: _useAndroidDownloadsPath,
          title: const Text('同步“下载”文件夹'),
          subtitle: const Text('路径：内部存储/Download'),
        ),
        _PathChoiceTile(
          selected: groupValue == 'custom',
          onTap: _chooseFolder,
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
        encryptionEnabled: _encryptionEnabled,
        cleanupPolicy: _cleanupPolicy,
        archivePath: '',
        sourceType: widget.wechatOnly
            ? widget.showAndroidFileAccessGuide || _wechatMode == 'files'
                  ? 'wechat'
                  : 'wechat_archive'
            : 'folder',
        includedFileTypes: _includedTypes.join(','),
      ),
    );
  }
}

class _PathChoiceTile extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget title;
  final Widget subtitle;

  const _PathChoiceTile({
    super.key,
    required this.selected,
    required this.onTap,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? colorScheme.primary : colorScheme.outline,
      ),
      title: title,
      subtitle: subtitle,
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
  late String _cleanupPolicy = widget.rootView.isWechatBackupRoot
      ? 'keep'
      : widget.rootView.root.cleanupPolicy == 'delete'
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
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _MetaChip(
              icon: widget.rootView.root.encryptionEnabled
                  ? Icons.lock_outline
                  : Icons.lock_open_outlined,
              label: widget.rootView.root.encryptionEnabled
                  ? '服务器端加密存储'
                  : '服务器端普通存储',
            ),
          ),
          const SizedBox(height: 12),
          if (widget.rootView.isWechatBackupRoot)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.shield_outlined),
              title: Text('保留微信本地文件'),
              subtitle: Text('微信目录不支持上传后删除，避免影响微信中的文件'),
            )
          else
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
  final bool encryptionEnabled;
  final String cleanupPolicy;
  final String archivePath;
  final String sourceType;
  final String includedFileTypes;

  const _SyncRootDraft({
    required this.localPath,
    required this.encryptedPath,
    required this.encryptionEnabled,
    required this.cleanupPolicy,
    required this.archivePath,
    this.sourceType = 'folder',
    this.includedFileTypes = '',
  });
}
