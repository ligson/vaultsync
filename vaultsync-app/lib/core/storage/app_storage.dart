import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/auth_models.dart';
import '../../features/device/device_models.dart';
import '../../features/media_backup/media_backup_models.dart';
import '../../features/sync/password_upload_key_deriver.dart';
import '../../features/sync/sync_models.dart';
import '../../features/sync/upload_key_store.dart';

abstract interface class SessionStore {
  Future<String?> loadAuthToken();

  Future<String?> loadAuthExpiresAt();

  Future<String?> loadDeviceId();

  Future<void> saveAuthSession(AuthSession session);

  Future<void> saveDevice(RegisteredDevice device);
}

List<Map<String, Object?>> _decodeUploadTaskJsonItems(List<String> rawItems) {
  return rawItems
      .map((raw) => (jsonDecode(raw) as Map).cast<String, Object?>())
      .toList(growable: false);
}

List<Map<String, Object?>> _decodeUploadTaskShardContents(
  List<String> contents,
) {
  return [
    for (final content in contents)
      for (final item in jsonDecode(content) as List<dynamic>)
        (item as Map).cast<String, Object?>(),
  ];
}

Map<int, String> _encodeUploadTaskShardContents(
  List<Map<String, Object?>> jsonItems,
) {
  final shards = <int, List<Map<String, Object?>>>{};
  for (final item in jsonItems) {
    final id = item['id'] as String? ?? '';
    (shards[_uploadTaskShardFor(id)] ??= []).add(item);
  }
  return {
    for (var index = 0; index < _uploadTaskShardCount; index += 1)
      index: jsonEncode(shards[index] ?? const <Map<String, Object?>>[]),
  };
}

const _uploadTaskShardCount = 32;

int _uploadTaskShardFor(String id) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(id)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash % _uploadTaskShardCount;
}

Future<Directory> _defaultUploadTaskDirectoryProvider() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/vaultsync/upload-tasks-v1');
}

typedef UploadTaskDirectoryProvider = Future<Directory> Function();

abstract interface class CurrentDeviceInfoStore {
  Future<String?> loadDeviceName();
}

abstract interface class RefreshTokenStore {
  Future<String?> loadRefreshToken();

  Future<String?> loadRefreshExpiresAt();
}

abstract interface class ServerSettingsStore {
  Future<String?> loadServerAddress();

  Future<void> saveServerAddress(String address);
}

abstract interface class AppThemePreferenceStore {
  Future<String?> loadAppTheme();

  Future<void> saveAppTheme(String themeId);
}

abstract interface class LocalSessionCleaner {
  Future<void> clearLocalSession();
}

abstract interface class SyncRootMappingStore {
  Future<List<LocalSyncRootMapping>> loadSyncRootMappings();

  Future<void> saveSyncRootMapping(LocalSyncRootMapping mapping);

  Future<void> saveSyncRootMappings(List<LocalSyncRootMapping> mappings);
}

abstract interface class UploadTaskStore {
  Future<List<LocalUploadTask>> loadUploadTasks();

  Future<void> saveUploadTasks(List<LocalUploadTask> tasks);
}

abstract interface class IncrementalUploadTaskStore implements UploadTaskStore {
  Future<void> saveUploadTask(LocalUploadTask task);

  Future<void> removeUploadTask(String taskId);
}

abstract interface class MediaBackupSourceStore {
  Future<List<LocalMediaBackupSource>> loadMediaBackupSources();

  Future<void> saveMediaBackupSources(List<LocalMediaBackupSource> sources);
}

abstract interface class SyncCursorStore {
  Future<int> loadRemoteCursor();

  Future<void> saveRemoteCursor(int cursor);
}

abstract interface class RemoteVersionIndexStore {
  Future<List<LocalRemoteVersionIndex>> loadRemoteVersionIndexes();

  Future<void> saveRemoteVersionIndex(LocalRemoteVersionIndex entry);

  Future<void> removeRemoteVersionIndex({
    required String syncRootId,
    required String objectId,
  });
}

abstract interface class SyncIssueStore {
  Future<List<LocalSyncIssue>> loadSyncIssues();

  Future<void> saveSyncIssue(LocalSyncIssue issue);

  Future<void> markSyncIssueResolved({required String issueId});
}

abstract interface class AutoSyncStatusStore {
  Future<AutoSyncStatus> loadAutoSyncStatus();

  Future<void> saveAutoSyncStatus(AutoSyncStatus status);
}

abstract interface class SyncOperationStatusStore {
  Future<List<LocalSyncOperationStatus>> loadSyncOperationStatuses();

  Future<void> saveSyncOperationStatus(LocalSyncOperationStatus status);
}

abstract interface class SyncHistoryStore {
  Future<List<LocalSyncHistoryEntry>> loadSyncHistory();

  Future<void> addSyncHistory(LocalSyncHistoryEntry entry);

  Future<void> clearSyncHistory();
}

class FileBrowserPreferences {
  final String viewMode;
  final String sortMode;
  final bool sortAscending;

  const FileBrowserPreferences({
    this.viewMode = 'list',
    this.sortMode = 'name',
    this.sortAscending = true,
  });
}

abstract interface class FileBrowserPreferenceStore {
  Future<FileBrowserPreferences> loadFileBrowserPreferences();

  Future<void> saveFileBrowserPreferences(FileBrowserPreferences preferences);
}

class AppStorage
    implements
        ServerSettingsStore,
        AppThemePreferenceStore,
        SessionStore,
        RefreshTokenStore,
        CurrentDeviceInfoStore,
        SyncRootMappingStore,
        IncrementalUploadTaskStore,
        MediaBackupSourceStore,
        SyncCursorStore,
        RemoteVersionIndexStore,
        SyncIssueStore,
        UploadKeyStore,
        AutoSyncStatusStore,
        SyncOperationStatusStore,
        SyncHistoryStore,
        FileBrowserPreferenceStore,
        LocalSessionCleaner {
  final PasswordUploadKeyDeriver uploadKeyDeriver;
  final UploadTaskDirectoryProvider uploadTaskDirectoryProvider;

  const AppStorage({
    this.uploadKeyDeriver = const PasswordUploadKeyDeriver(),
    this.uploadTaskDirectoryProvider = _defaultUploadTaskDirectoryProvider,
  });

  static const _authTokenKey = 'vaultsync.auth.token';
  static const _serverAddressKey = 'vaultsync.server.address';
  static const _appThemeKey = 'vaultsync.appearance.theme';
  static const _tokenIdKey = 'vaultsync.auth.token_id';
  static const _userIdKey = 'vaultsync.auth.user_id';
  static const _expiresAtKey = 'vaultsync.auth.expires_at';
  static const _refreshTokenKey = 'vaultsync.auth.refresh_token';
  static const _refreshExpiresAtKey = 'vaultsync.auth.refresh_expires_at';
  static const _deviceIdKey = 'vaultsync.device.id';
  static const _deviceNameKey = 'vaultsync.device.name';
  static const _devicePlatformKey = 'vaultsync.device.platform';
  static const _syncRootMappingsKey = 'vaultsync.sync_roots.mappings';
  static const _uploadTasksKey = 'vaultsync.upload_tasks';
  static const _uploadTaskManifestFileName = 'manifest.json';
  static const _uploadTaskStorageVersion = 1;
  static const _mediaBackupSourcesKey = 'vaultsync.media_backup.sources';
  static const _remoteCursorKey = 'vaultsync.sync.remote_cursor';
  static const _remoteVersionIndexesKey = 'vaultsync.sync.remote_versions';
  static const _syncIssuesKey = 'vaultsync.sync.issues';
  static const _uploadContentKey = 'vaultsync.crypto.upload.content_key';
  static const _uploadMetadataKey = 'vaultsync.crypto.upload.metadata_key';
  static const _autoSyncStatusKey = 'vaultsync.sync.auto_status';
  static const _syncOperationStatusesKey = 'vaultsync.sync.operation_statuses';
  static const _syncHistoryKey = 'vaultsync.sync.history';
  static const _fileBrowserViewModeKey = 'vaultsync.file_browser.view_mode';
  static const _fileBrowserSortModeKey = 'vaultsync.file_browser.sort_mode';
  static const _fileBrowserSortAscendingKey =
      'vaultsync.file_browser.sort_ascending';
  static const _maxSyncHistoryItems = 200;

  @override
  Future<String?> loadServerAddress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverAddressKey);
  }

  @override
  Future<void> saveServerAddress(String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverAddressKey, address);
  }

  @override
  Future<String?> loadAppTheme() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_appThemeKey);
  }

  @override
  Future<void> saveAppTheme(String themeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appThemeKey, themeId);
  }

  @override
  Future<void> saveAuthSession(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_authTokenKey, session.token);
    await prefs.setString(_tokenIdKey, session.tokenId);
    await prefs.setString(_userIdKey, session.userId);
    await prefs.setString(_expiresAtKey, session.expiresAt);
    if (session.refreshToken.isNotEmpty) {
      await prefs.setString(_refreshTokenKey, session.refreshToken);
    }
    if (session.refreshExpiresAt.isNotEmpty) {
      await prefs.setString(_refreshExpiresAtKey, session.refreshExpiresAt);
    }
  }

  @override
  Future<void> saveDevice(RegisteredDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_deviceIdKey, device.id);
    await prefs.setString(_deviceNameKey, device.name);
    await prefs.setString(_devicePlatformKey, device.platform);
  }

  @override
  Future<String?> loadAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_authTokenKey);
  }

  @override
  Future<String?> loadAuthExpiresAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_expiresAtKey);
  }

  @override
  Future<String?> loadRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshTokenKey);
  }

  @override
  Future<String?> loadRefreshExpiresAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshExpiresAtKey);
  }

  @override
  Future<String?> loadDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_deviceIdKey);
  }

  @override
  Future<String?> loadDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_deviceNameKey);
  }

  @override
  Future<void> clearLocalSession() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _authTokenKey,
      _tokenIdKey,
      _userIdKey,
      _expiresAtKey,
      _refreshTokenKey,
      _refreshExpiresAtKey,
      _deviceIdKey,
      _deviceNameKey,
      _devicePlatformKey,
      _remoteCursorKey,
      _remoteVersionIndexesKey,
      _syncIssuesKey,
      _uploadContentKey,
      _uploadMetadataKey,
      _autoSyncStatusKey,
      _syncHistoryKey,
    ]) {
      await prefs.remove(key);
    }
  }

  @override
  Future<List<LocalSyncRootMapping>> loadSyncRootMappings() async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_syncRootMappingsKey) ?? const [];
    return rawItems
        .map((raw) => jsonDecode(raw) as Map<String, Object?>)
        .map(LocalSyncRootMapping.fromJson)
        .toList();
  }

  @override
  Future<void> saveSyncRootMapping(LocalSyncRootMapping mapping) async {
    final mappings = await loadSyncRootMappings();
    final nextMappings = [
      for (final existing in mappings)
        if (existing.syncRootId != mapping.syncRootId) existing,
      mapping,
    ];
    await saveSyncRootMappings(nextMappings);
  }

  @override
  Future<void> saveSyncRootMappings(List<LocalSyncRootMapping> mappings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _syncRootMappingsKey,
      mappings.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Future<List<LocalUploadTask>> loadUploadTasks() async {
    final directory = await _prepareUploadTaskDirectory();
    final contents = await Future.wait([
      for (var index = 0; index < _uploadTaskShardCount; index += 1)
        _readUploadTaskShard(directory, index),
    ]);
    final nonEmptyContents = contents.where((item) => item.isNotEmpty).toList();
    if (nonEmptyContents.isEmpty) {
      return const [];
    }
    final decodedItems = await compute(
      _decodeUploadTaskShardContents,
      nonEmptyContents,
    );
    return decodedItems.map(LocalUploadTask.fromJson).toList()
      ..sort((left, right) => left.id.compareTo(right.id));
  }

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {
    final directory = await _prepareUploadTaskDirectory();
    await _writeUploadTaskShards(directory, tasks);
  }

  @override
  Future<void> saveUploadTask(LocalUploadTask task) async {
    final directory = await _prepareUploadTaskDirectory();
    final shardIndex = _uploadTaskShardFor(task.id);
    final tasks = await _loadUploadTaskShard(directory, shardIndex);
    final nextTasks = [
      for (final existing in tasks)
        if (existing.id != task.id) existing,
      task,
    ];
    await _writeUploadTaskShard(directory, shardIndex, nextTasks);
  }

  @override
  Future<void> removeUploadTask(String taskId) async {
    final directory = await _prepareUploadTaskDirectory();
    final shardIndex = _uploadTaskShardFor(taskId);
    final tasks = await _loadUploadTaskShard(directory, shardIndex);
    final nextTasks = [
      for (final task in tasks)
        if (task.id != taskId) task,
    ];
    if (nextTasks.length == tasks.length) {
      return;
    }
    await _writeUploadTaskShard(directory, shardIndex, nextTasks);
  }

  Future<Directory> _prepareUploadTaskDirectory() async {
    final directory = await uploadTaskDirectoryProvider();
    await directory.create(recursive: true);
    final manifest = File(
      '${directory.path}${Platform.pathSeparator}$_uploadTaskManifestFileName',
    );
    await _recoverAtomicFile(manifest);
    if (await manifest.exists()) {
      try {
        final value = jsonDecode(await manifest.readAsString());
        if (value is Map && value['version'] == _uploadTaskStorageVersion) {
          return directory;
        }
      } catch (_) {
        // 继续使用旧偏好和可恢复分片重建，不丢弃任何可读取任务。
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyItems = prefs.getStringList(_uploadTasksKey) ?? const [];
    final legacyTasks = legacyItems.isEmpty
        ? const <LocalUploadTask>[]
        : (await compute(
            _decodeUploadTaskJsonItems,
            legacyItems,
          )).map(LocalUploadTask.fromJson).toList();
    final recoveredTasks = <LocalUploadTask>[];
    for (var index = 0; index < _uploadTaskShardCount; index += 1) {
      recoveredTasks.addAll(await _loadUploadTaskShard(directory, index));
    }
    final tasksById = {
      for (final task in legacyTasks) task.id: task,
      for (final task in recoveredTasks) task.id: task,
    };
    await _writeUploadTaskShards(directory, tasksById.values.toList());
    await _writeAtomicText(
      manifest,
      jsonEncode({
        'version': _uploadTaskStorageVersion,
        'shard_count': _uploadTaskShardCount,
        'legacy_key_preserved': true,
        'migrated_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    return directory;
  }

  Future<void> _writeUploadTaskShards(
    Directory directory,
    List<LocalUploadTask> tasks,
  ) async {
    final contents = await compute(
      _encodeUploadTaskShardContents,
      tasks.map((task) => task.toJson()).toList(growable: false),
    );
    for (var index = 0; index < _uploadTaskShardCount; index += 1) {
      final nextContent = contents[index] ?? '[]';
      final currentContent = await _readUploadTaskShard(directory, index);
      if (currentContent == nextContent) {
        continue;
      }
      await _writeAtomicText(
        _uploadTaskShardFile(directory, index),
        nextContent,
      );
    }
  }

  Future<List<LocalUploadTask>> _loadUploadTaskShard(
    Directory directory,
    int index,
  ) async {
    final content = await _readUploadTaskShard(directory, index);
    if (content.isEmpty) {
      return const [];
    }
    try {
      final items = await compute(_decodeUploadTaskShardContents, <String>[
        content,
      ]);
      return items.map(LocalUploadTask.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String> _readUploadTaskShard(Directory directory, int index) async {
    final file = _uploadTaskShardFile(directory, index);
    await _recoverAtomicFile(file);
    if (!await file.exists()) {
      return '';
    }
    return file.readAsString();
  }

  Future<void> _writeUploadTaskShard(
    Directory directory,
    int index,
    List<LocalUploadTask> tasks,
  ) async {
    tasks.sort((left, right) => left.id.compareTo(right.id));
    await _writeAtomicText(
      _uploadTaskShardFile(directory, index),
      jsonEncode(tasks.map((task) => task.toJson()).toList(growable: false)),
    );
  }

  File _uploadTaskShardFile(Directory directory, int index) {
    final name = index.toString().padLeft(2, '0');
    return File('${directory.path}${Platform.pathSeparator}tasks-$name.json');
  }

  Future<void> _writeAtomicText(File target, String content) async {
    await target.parent.create(recursive: true);
    final next = File('${target.path}.next');
    final backup = File('${target.path}.backup');
    if (await next.exists()) {
      await next.delete();
    }
    await next.writeAsString(content, flush: true);
    if (await backup.exists()) {
      await backup.delete();
    }
    if (await target.exists()) {
      await target.rename(backup.path);
    }
    try {
      await next.rename(target.path);
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  Future<void> _recoverAtomicFile(File target) async {
    final next = File('${target.path}.next');
    final backup = File('${target.path}.backup');
    if (!await target.exists()) {
      if (await next.exists()) {
        await next.rename(target.path);
      } else if (await backup.exists()) {
        await backup.rename(target.path);
      }
    }
    if (await target.exists() && await next.exists()) {
      await next.delete();
    }
    if (await target.exists() && await backup.exists()) {
      await backup.delete();
    }
  }

  @override
  Future<List<LocalMediaBackupSource>> loadMediaBackupSources() async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_mediaBackupSourcesKey) ?? const [];
    return rawItems
        .map((raw) => jsonDecode(raw) as Map<String, Object?>)
        .map(LocalMediaBackupSource.fromJson)
        .toList();
  }

  @override
  Future<void> saveMediaBackupSources(
    List<LocalMediaBackupSource> sources,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _mediaBackupSourcesKey,
      sources.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Future<int> loadRemoteCursor() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_remoteCursorKey) ?? 0;
  }

  @override
  Future<void> saveRemoteCursor(int cursor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_remoteCursorKey, cursor);
  }

  @override
  Future<List<LocalRemoteVersionIndex>> loadRemoteVersionIndexes() async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_remoteVersionIndexesKey) ?? const [];
    return rawItems
        .map((raw) => jsonDecode(raw) as Map<String, Object?>)
        .map(LocalRemoteVersionIndex.fromJson)
        .toList();
  }

  @override
  Future<void> saveRemoteVersionIndex(LocalRemoteVersionIndex entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await loadRemoteVersionIndexes();
    final nextEntries = [
      for (final existing in entries)
        if (existing.syncRootId != entry.syncRootId ||
            existing.objectId != entry.objectId)
          existing,
      entry,
    ];
    await prefs.setStringList(
      _remoteVersionIndexesKey,
      nextEntries.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Future<void> removeRemoteVersionIndex({
    required String syncRootId,
    required String objectId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await loadRemoteVersionIndexes();
    final nextEntries = [
      for (final existing in entries)
        if (existing.syncRootId != syncRootId || existing.objectId != objectId)
          existing,
    ];
    await prefs.setStringList(
      _remoteVersionIndexesKey,
      nextEntries.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Future<List<LocalSyncIssue>> loadSyncIssues() async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_syncIssuesKey) ?? const [];
    return rawItems
        .map((raw) => jsonDecode(raw) as Map<String, Object?>)
        .map(LocalSyncIssue.fromJson)
        .toList();
  }

  @override
  Future<void> saveSyncIssue(LocalSyncIssue issue) async {
    final prefs = await SharedPreferences.getInstance();
    final issues = await loadSyncIssues();
    final nextIssues = [
      for (final existing in issues)
        if (existing.id != issue.id) existing,
      issue,
    ];
    await prefs.setStringList(
      _syncIssuesKey,
      nextIssues.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Future<void> markSyncIssueResolved({required String issueId}) async {
    final prefs = await SharedPreferences.getInstance();
    final issues = await loadSyncIssues();
    final nextIssues = [
      for (final issue in issues)
        if (issue.id == issueId)
          LocalSyncIssue(
            id: issue.id,
            type: issue.type,
            syncRootId: issue.syncRootId,
            objectId: issue.objectId,
            versionId: issue.versionId,
            relativePath: issue.relativePath,
            localPath: issue.localPath,
            message: issue.message,
            status: 'resolved',
            createdAt: issue.createdAt,
          )
        else
          issue,
    ];
    await prefs.setStringList(
      _syncIssuesKey,
      nextIssues.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Future<AutoSyncStatus> loadAutoSyncStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_autoSyncStatusKey);
    if (raw == null || raw.isEmpty) {
      return const AutoSyncStatus();
    }
    return AutoSyncStatus.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<void> saveAutoSyncStatus(AutoSyncStatus status) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_autoSyncStatusKey, jsonEncode(status.toJson()));
  }

  @override
  Future<List<LocalSyncOperationStatus>> loadSyncOperationStatuses() async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_syncOperationStatusesKey) ?? const [];
    return rawItems
        .map((raw) => jsonDecode(raw) as Map<String, Object?>)
        .map(LocalSyncOperationStatus.fromJson)
        .toList();
  }

  @override
  Future<void> saveSyncOperationStatus(LocalSyncOperationStatus status) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadSyncOperationStatuses();
    final next = [
      for (final item in existing)
        if (item.id != status.id) item,
      status,
    ]..sort((left, right) => left.id.compareTo(right.id));
    await prefs.setStringList(
      _syncOperationStatusesKey,
      next.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Future<List<LocalSyncHistoryEntry>> loadSyncHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_syncHistoryKey) ?? const [];
    return rawItems
        .map((raw) => jsonDecode(raw) as Map<String, Object?>)
        .map(LocalSyncHistoryEntry.fromJson)
        .toList()
      ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
  }

  @override
  Future<void> addSyncHistory(LocalSyncHistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await loadSyncHistory();
    final nextItems = [
      entry,
      ...items,
    ].take(_maxSyncHistoryItems).toList(growable: false);
    await prefs.setStringList(
      _syncHistoryKey,
      nextItems.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Future<void> clearSyncHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_syncHistoryKey);
  }

  @override
  Future<FileBrowserPreferences> loadFileBrowserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    return FileBrowserPreferences(
      viewMode: prefs.getString(_fileBrowserViewModeKey) ?? 'list',
      sortMode: prefs.getString(_fileBrowserSortModeKey) ?? 'name',
      sortAscending: prefs.getBool(_fileBrowserSortAscendingKey) ?? true,
    );
  }

  @override
  Future<void> saveFileBrowserPreferences(
    FileBrowserPreferences preferences,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(_fileBrowserViewModeKey, preferences.viewMode),
      prefs.setString(_fileBrowserSortModeKey, preferences.sortMode),
      prefs.setBool(_fileBrowserSortAscendingKey, preferences.sortAscending),
    ]);
  }

  @override
  Future<UploadKeyMaterial> loadUploadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final existingContentKey = prefs.getString(_uploadContentKey);
    final existingMetadataKey = prefs.getString(_uploadMetadataKey);
    if (existingContentKey != null && existingMetadataKey != null) {
      return UploadKeyMaterial(
        contentKeyBytes: base64Url.decode(existingContentKey),
        metadataKeyBytes: base64Url.decode(existingMetadataKey),
      );
    }

    throw const MissingUploadKeyException();
  }

  @override
  Future<UploadKeyMaterial> deriveAndSaveUploadKeys({
    required String email,
    required String password,
  }) async {
    final keys = await uploadKeyDeriver.derive(
      email: email,
      password: password,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _uploadContentKey,
      base64Url.encode(keys.contentKeyBytes),
    );
    await prefs.setString(
      _uploadMetadataKey,
      base64Url.encode(keys.metadataKeyBytes),
    );
    return keys;
  }
}
