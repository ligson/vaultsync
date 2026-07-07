import 'dart:convert';

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

abstract interface class ServerSettingsStore {
  Future<String?> loadServerAddress();

  Future<void> saveServerAddress(String address);
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

abstract interface class SyncHistoryStore {
  Future<List<LocalSyncHistoryEntry>> loadSyncHistory();

  Future<void> addSyncHistory(LocalSyncHistoryEntry entry);

  Future<void> clearSyncHistory();
}

class AppStorage
    implements
        ServerSettingsStore,
        SessionStore,
        SyncRootMappingStore,
        UploadTaskStore,
        MediaBackupSourceStore,
        SyncCursorStore,
        RemoteVersionIndexStore,
        SyncIssueStore,
        UploadKeyStore,
        AutoSyncStatusStore,
        SyncHistoryStore,
        LocalSessionCleaner {
  final PasswordUploadKeyDeriver uploadKeyDeriver;

  const AppStorage({this.uploadKeyDeriver = const PasswordUploadKeyDeriver()});

  static const _authTokenKey = 'vaultsync.auth.token';
  static const _serverAddressKey = 'vaultsync.server.address';
  static const _tokenIdKey = 'vaultsync.auth.token_id';
  static const _userIdKey = 'vaultsync.auth.user_id';
  static const _expiresAtKey = 'vaultsync.auth.expires_at';
  static const _deviceIdKey = 'vaultsync.device.id';
  static const _deviceNameKey = 'vaultsync.device.name';
  static const _devicePlatformKey = 'vaultsync.device.platform';
  static const _syncRootMappingsKey = 'vaultsync.sync_roots.mappings';
  static const _uploadTasksKey = 'vaultsync.upload_tasks';
  static const _mediaBackupSourcesKey = 'vaultsync.media_backup.sources';
  static const _remoteCursorKey = 'vaultsync.sync.remote_cursor';
  static const _remoteVersionIndexesKey = 'vaultsync.sync.remote_versions';
  static const _syncIssuesKey = 'vaultsync.sync.issues';
  static const _uploadContentKey = 'vaultsync.crypto.upload.content_key';
  static const _uploadMetadataKey = 'vaultsync.crypto.upload.metadata_key';
  static const _autoSyncStatusKey = 'vaultsync.sync.auto_status';
  static const _syncHistoryKey = 'vaultsync.sync.history';
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
  Future<void> saveAuthSession(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_authTokenKey, session.token);
    await prefs.setString(_tokenIdKey, session.tokenId);
    await prefs.setString(_userIdKey, session.userId);
    await prefs.setString(_expiresAtKey, session.expiresAt);
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
  Future<String?> loadDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_deviceIdKey);
  }

  @override
  Future<void> clearLocalSession() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _authTokenKey,
      _tokenIdKey,
      _userIdKey,
      _expiresAtKey,
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
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_uploadTasksKey) ?? const [];
    return rawItems
        .map((raw) => jsonDecode(raw) as Map<String, Object?>)
        .map(LocalUploadTask.fromJson)
        .toList();
  }

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _uploadTasksKey,
      tasks.map((item) => jsonEncode(item.toJson())).toList(),
    );
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
