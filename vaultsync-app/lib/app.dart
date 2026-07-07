import 'package:flutter/material.dart';

import 'core/config/app_config.dart';
import 'core/device/device_profile.dart';
import 'core/network/api_client.dart';
import 'core/network/api_exception.dart';
import 'core/storage/app_storage.dart';
import 'features/auth/auth_service.dart';
import 'features/auth/login_screen.dart';
import 'features/device/device_service.dart';
import 'features/download/download_service.dart';
import 'features/media_backup/media_upload_content_reader.dart';
import 'features/media_backup/photo_manager_media_gateway.dart';
import 'features/sync/encrypted_download_payload_decrypter.dart';
import 'features/sync/encrypted_upload_payload_preparer.dart';
import 'features/sync/local_cleanup_executor.dart';
import 'features/sync/local_download_writer.dart';
import 'features/sync/local_remote_delete_handler.dart';
import 'features/sync/local_upload_executor.dart';
import 'features/sync/remote_metadata_decrypter.dart';
import 'features/sync/sync_home_screen.dart';
import 'features/sync/sync_pull_executor.dart';
import 'features/sync/sync_service.dart';
import 'features/sync/upload_api_service.dart';
import 'features/sync/upload_key_store.dart';

class VaultSyncApp extends StatefulWidget {
  final AppConfig config;
  final SessionStore storage;
  final SyncRootMappingStore syncRootMappings;
  final UploadTaskStore uploadTasks;
  final SyncCursorStore syncCursors;
  final RemoteVersionIndexStore remoteVersions;
  final SyncIssueStore syncIssues;
  final UploadKeyStore uploadKeys;
  final ServerSettingsStore serverSettings;
  final AutoSyncStatusStore? autoSyncStatus;
  final SyncHistoryStore? syncHistory;
  final AuthGateway? authGateway;
  final SyncRootGateway? syncRoots;
  final UploadGateway? uploads;
  final LocalUploadExecutionGateway? uploadExecutor;
  final DownloadGateway? downloads;
  final RemoteSyncPullGateway? remotePullExecutor;
  final bool autoSyncEnabled;

  VaultSyncApp({
    super.key,
    AppConfig? config,
    SessionStore? storage,
    SyncRootMappingStore? syncRootMappings,
    UploadTaskStore? uploadTasks,
    SyncCursorStore? syncCursors,
    RemoteVersionIndexStore? remoteVersions,
    SyncIssueStore? syncIssues,
    UploadKeyStore? uploadKeys,
    ServerSettingsStore? serverSettings,
    AutoSyncStatusStore? autoSyncStatus,
    SyncHistoryStore? syncHistory,
    this.authGateway,
    this.syncRoots,
    this.uploads,
    this.uploadExecutor,
    this.downloads,
    this.remotePullExecutor,
    this.autoSyncEnabled = false,
  }) : config = config ?? AppConfig.fromEnvironment(const {}),
       storage = storage ?? const AppStorage(),
       syncRootMappings = _resolveSyncRootMappings(storage, syncRootMappings),
       uploadTasks = _resolveUploadTasks(storage, uploadTasks),
       syncCursors = _resolveSyncCursors(storage, syncCursors),
       remoteVersions = _resolveRemoteVersions(storage, remoteVersions),
       syncIssues = _resolveSyncIssues(storage, syncIssues),
       uploadKeys = _resolveUploadKeys(storage, uploadKeys),
       serverSettings = _resolveServerSettings(storage, serverSettings),
       autoSyncStatus = _resolveAutoSyncStatus(storage, autoSyncStatus),
       syncHistory = _resolveSyncHistory(storage, syncHistory);

  @override
  State<VaultSyncApp> createState() => _VaultSyncAppState();

  static SyncRootMappingStore _resolveSyncRootMappings(
    SessionStore? storage,
    SyncRootMappingStore? syncRootMappings,
  ) {
    if (syncRootMappings != null) {
      return syncRootMappings;
    }
    final existingStorage = storage;
    if (existingStorage is SyncRootMappingStore) {
      return existingStorage as SyncRootMappingStore;
    }
    return const AppStorage();
  }

  static UploadTaskStore _resolveUploadTasks(
    SessionStore? storage,
    UploadTaskStore? uploadTasks,
  ) {
    if (uploadTasks != null) {
      return uploadTasks;
    }
    final existingStorage = storage;
    if (existingStorage is UploadTaskStore) {
      return existingStorage as UploadTaskStore;
    }
    return const AppStorage();
  }

  static UploadKeyStore _resolveUploadKeys(
    SessionStore? storage,
    UploadKeyStore? uploadKeys,
  ) {
    if (uploadKeys != null) {
      return uploadKeys;
    }
    final existingStorage = storage;
    if (existingStorage is UploadKeyStore) {
      return existingStorage as UploadKeyStore;
    }
    return const AppStorage();
  }

  static ServerSettingsStore _resolveServerSettings(
    SessionStore? storage,
    ServerSettingsStore? serverSettings,
  ) {
    if (serverSettings != null) {
      return serverSettings;
    }
    final existingStorage = storage;
    if (existingStorage is ServerSettingsStore) {
      return existingStorage as ServerSettingsStore;
    }
    return const AppStorage();
  }

  static SyncCursorStore _resolveSyncCursors(
    SessionStore? storage,
    SyncCursorStore? syncCursors,
  ) {
    if (syncCursors != null) {
      return syncCursors;
    }
    final existingStorage = storage;
    if (existingStorage is SyncCursorStore) {
      return existingStorage as SyncCursorStore;
    }
    return const AppStorage();
  }

  static RemoteVersionIndexStore _resolveRemoteVersions(
    SessionStore? storage,
    RemoteVersionIndexStore? remoteVersions,
  ) {
    if (remoteVersions != null) {
      return remoteVersions;
    }
    final existingStorage = storage;
    if (existingStorage is RemoteVersionIndexStore) {
      return existingStorage as RemoteVersionIndexStore;
    }
    return const AppStorage();
  }

  static SyncIssueStore _resolveSyncIssues(
    SessionStore? storage,
    SyncIssueStore? syncIssues,
  ) {
    if (syncIssues != null) {
      return syncIssues;
    }
    final existingStorage = storage;
    if (existingStorage is SyncIssueStore) {
      return existingStorage as SyncIssueStore;
    }
    return const AppStorage();
  }

  static AutoSyncStatusStore? _resolveAutoSyncStatus(
    SessionStore? storage,
    AutoSyncStatusStore? autoSyncStatus,
  ) {
    if (autoSyncStatus != null) {
      return autoSyncStatus;
    }
    final existingStorage = storage;
    if (existingStorage is AutoSyncStatusStore) {
      return existingStorage as AutoSyncStatusStore;
    }
    if (existingStorage == null) {
      return const AppStorage();
    }
    return null;
  }

  static SyncHistoryStore? _resolveSyncHistory(
    SessionStore? storage,
    SyncHistoryStore? syncHistory,
  ) {
    if (syncHistory != null) {
      return syncHistory;
    }
    final existingStorage = storage;
    if (existingStorage is SyncHistoryStore) {
      return existingStorage as SyncHistoryStore;
    }
    if (existingStorage == null) {
      return const AppStorage();
    }
    return null;
  }
}

class _VaultSyncAppState extends State<VaultSyncApp> {
  late Uri _apiBaseUrl;
  bool _serverSettingsLoaded = false;

  @override
  void initState() {
    super.initState();
    _apiBaseUrl = widget.config.apiBaseUrl;
    _loadServerSettings();
  }

  @override
  Widget build(BuildContext context) {
    if (!_serverSettingsLoaded) {
      return MaterialApp(
        title: 'VaultSync',
        theme: _theme(),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    final authApiClient = ApiClient(baseUrl: _apiBaseUrl);
    final auth = widget.authGateway ?? AuthService(authApiClient);
    final apiClient = ApiClient(
      baseUrl: _apiBaseUrl,
      sessionStore: widget.storage,
      refreshAuthSession: auth.refresh,
    );
    final devices = DeviceService(apiClient);
    final resolvedSyncRoots = widget.syncRoots ?? SyncService(apiClient);
    final resolvedSyncChanges = resolvedSyncRoots is SyncChangeGateway
        ? resolvedSyncRoots as SyncChangeGateway
        : SyncService(apiClient);
    final resolvedRemoteBackups = resolvedSyncRoots is RemoteBackupGateway
        ? resolvedSyncRoots as RemoteBackupGateway
        : SyncService(apiClient);
    final resolvedRemoteObjectDeletes =
        resolvedSyncRoots is RemoteObjectDeleteGateway
        ? resolvedSyncRoots as RemoteObjectDeleteGateway
        : SyncService(apiClient);
    final resolvedUploads = widget.uploads ?? UploadApiService(apiClient);
    final resolvedDownloads = widget.downloads ?? DownloadService(apiClient);
    final deviceProfile = DeviceProfile.current();
    final mediaGateway = const PhotoManagerMediaGateway();
    final resolvedUploadExecutor =
        widget.uploadExecutor ??
        LocalUploadExecutor(
          sessionStore: widget.storage,
          uploadTasks: widget.uploadTasks,
          uploads: resolvedUploads,
          payloadPreparer: StoredEncryptedUploadPayloadPreparer(
            keyStore: widget.uploadKeys,
            contentReader: MediaAwareUploadContentReader(
              fileReader: const FileUploadContentReader(),
              media: mediaGateway,
            ),
          ),
          postUploadCleaner: LocalCleanupExecutor(
            mappings: widget.syncRootMappings,
            uploadTasks: widget.uploadTasks,
            mediaCleaner: mediaGateway,
          ),
        );
    final resolvedRemotePullExecutor =
        widget.remotePullExecutor ??
        SyncPullExecutor(
          sessionStore: widget.storage,
          cursorStore: widget.syncCursors,
          changes: resolvedSyncChanges,
          downloads: resolvedDownloads,
          decrypter: StoredEncryptedDownloadPayloadDecrypter(
            keyStore: widget.uploadKeys,
          ),
          writer: LocalDownloadWriter(
            mappings: widget.syncRootMappings,
            remoteVersions: widget.remoteVersions,
            syncIssues: widget.syncIssues,
            conflictDeviceName: deviceProfile.name,
          ),
          deleteHandler: LocalRemoteDeleteHandler(
            remoteVersions: widget.remoteVersions,
            syncIssues: widget.syncIssues,
          ),
        );
    return MaterialApp(
      title: 'VaultSync',
      theme: _theme(),
      home: FutureBuilder<bool>(
        future: _hasLocalSession(auth),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data == true) {
            return SyncHomeScreen(
              storage: widget.storage,
              syncRootMappings: widget.syncRootMappings,
              uploadTasks: widget.uploadTasks,
              syncIssues: widget.syncIssues,
              autoSyncStatus: widget.autoSyncStatus,
              syncHistory: widget.syncHistory,
              syncRoots: resolvedSyncRoots,
              uploadExecutor: resolvedUploadExecutor,
              remotePullExecutor: resolvedRemotePullExecutor,
              remoteBackups: resolvedRemoteBackups,
              remoteObjectDeletes: resolvedRemoteObjectDeletes,
              remoteMetadataDecrypter: StoredRemoteMetadataDecrypter(
                keyStore: widget.uploadKeys,
              ),
              mediaBackupSources: widget.storage is MediaBackupSourceStore
                  ? widget.storage as MediaBackupSourceStore
                  : null,
              mediaGateway: mediaGateway,
              autoSyncEnabled: widget.autoSyncEnabled,
              onSignOut: _signOut,
            );
          }
          return LoginScreen(
            auth: auth,
            devices: devices,
            storage: widget.storage,
            syncRootMappings: widget.syncRootMappings,
            uploadTasks: widget.uploadTasks,
            syncIssues: widget.syncIssues,
            autoSyncStatus: widget.autoSyncStatus,
            syncHistory: widget.syncHistory,
            uploadKeys: widget.uploadKeys,
            deviceProfile: deviceProfile,
            syncRoots: resolvedSyncRoots,
            uploadExecutor: resolvedUploadExecutor,
            remotePullExecutor: resolvedRemotePullExecutor,
            remoteBackups: resolvedRemoteBackups,
            remoteObjectDeletes: resolvedRemoteObjectDeletes,
            remoteMetadataDecrypter: StoredRemoteMetadataDecrypter(
              keyStore: widget.uploadKeys,
            ),
            mediaBackupSources: widget.storage is MediaBackupSourceStore
                ? widget.storage as MediaBackupSourceStore
                : null,
            mediaGateway: mediaGateway,
            autoSyncEnabled: widget.autoSyncEnabled,
            onSignOut: _signOut,
            serverAddress: _apiBaseUrl.toString(),
            onServerAddressChanged: _saveServerAddress,
            onTestServerConnection: _testServerConnection,
          );
        },
      ),
    );
  }

  Future<bool> _hasLocalSession(AuthGateway auth) async {
    final token = await widget.storage.loadAuthToken();
    final expiresAt = await widget.storage.loadAuthExpiresAt();
    final deviceId = await widget.storage.loadDeviceId();
    if (token == null ||
        token.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty ||
        expiresAt == null ||
        expiresAt.isEmpty) {
      return false;
    }
    final expiresAtTime = DateTime.tryParse(expiresAt);
    if (expiresAtTime == null) {
      return false;
    }
    final now = DateTime.now().toUtc();
    final expiresAtUtc = expiresAtTime.toUtc();
    if (!expiresAtUtc.isAfter(now)) {
      return false;
    }
    if (expiresAtUtc.difference(now) <= const Duration(hours: 1)) {
      try {
        final refreshed = await auth.refresh(token);
        await widget.storage.saveAuthSession(refreshed);
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  ThemeData _theme() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      useMaterial3: true,
    );
  }

  Future<void> _loadServerSettings() async {
    final savedAddress = await widget.serverSettings.loadServerAddress();
    final savedUri = _tryParseServerAddress(savedAddress);
    if (!mounted) {
      return;
    }
    setState(() {
      _apiBaseUrl = savedUri ?? widget.config.apiBaseUrl;
      _serverSettingsLoaded = true;
    });
  }

  Future<void> _saveServerAddress(String address) async {
    final uri = _parseServerAddress(address);
    await widget.serverSettings.saveServerAddress(uri.toString());
    if (!mounted) {
      return;
    }
    setState(() {
      _apiBaseUrl = uri;
    });
  }

  Future<void> _testServerConnection(String address) async {
    final uri = _parseServerAddress(address);
    await AuthService(ApiClient(baseUrl: uri)).ping();
  }

  Uri? _tryParseServerAddress(String? address) {
    if (address == null || address.trim().isEmpty) {
      return null;
    }
    try {
      return _parseServerAddress(address);
    } catch (_) {
      return null;
    }
  }

  Uri _parseServerAddress(String address) {
    final uri = Uri.tryParse(address.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const ApiException(
        statusCode: 0,
        code: 'invalid_server_address',
        message: '请输入有效的后端地址，例如 http://127.0.0.1:8080',
      );
    }
    return uri;
  }

  Future<void> _signOut() async {
    final storage = widget.storage;
    if (storage is LocalSessionCleaner) {
      await (storage as LocalSessionCleaner).clearLocalSession();
    }
    if (mounted) {
      setState(() {});
    }
  }
}
