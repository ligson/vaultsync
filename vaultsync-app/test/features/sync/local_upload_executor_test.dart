import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/local_upload_executor.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/upload_api_service.dart';

void main() {
  test(
    'executePendingUploads uploads prepared ciphertext and marks task uploaded',
    () async {
      final uploadTasks = FakeUploadTaskStore([
        LocalUploadTask(
          id: 'root-1:a.jpg',
          syncRootId: 'root-1',
          localPath: '/Users/alice/Photos/a.jpg',
          relativePath: 'a.jpg',
          sizeBytes: 3,
          modifiedAt: DateTime.utc(2026, 6, 27, 9),
          status: 'pending',
          attempts: 0,
          createdAt: DateTime.utc(2026, 6, 27, 10),
        ),
      ]);
      final uploads = FakeUploadGateway();
      final cleaner = FakePostUploadCleaner();
      final executor = LocalUploadExecutor(
        sessionStore: FakeSessionStore(
          token: 'server-token',
          deviceId: 'device-1',
        ),
        uploadTasks: uploadTasks,
        uploads: uploads,
        payloadPreparer: const FakeUploadPayloadPreparer(),
        postUploadCleaner: cleaner,
        objectIdForTask: (_) => 'object-1',
        versionIdForTask: (_) => 'version-1',
        chunkSize: 3,
      );

      final result = await executor.executePendingUploads();

      expect(result.uploadedCount, 1);
      expect(uploads.createdSyncRootId, 'root-1');
      expect(uploads.uploadedParts, [
        [1, 2, 3],
      ]);
      expect(uploadTasks.saved.single.status, 'uploaded');
      expect(cleaner.callCount, 1);
    },
  );

  test(
    'executePendingUploads splits prepared ciphertext into chunks',
    () async {
      final uploadTasks = FakeUploadTaskStore([
        LocalUploadTask(
          id: 'root-1:a.jpg',
          syncRootId: 'root-1',
          localPath: '/Users/alice/Photos/a.jpg',
          relativePath: 'a.jpg',
          sizeBytes: 7,
          modifiedAt: DateTime.utc(2026, 6, 27, 9),
          status: 'pending',
          attempts: 0,
          createdAt: DateTime.utc(2026, 6, 27, 10),
        ),
      ]);
      final uploads = FakeUploadGateway();
      final executor = LocalUploadExecutor(
        sessionStore: FakeSessionStore(
          token: 'server-token',
          deviceId: 'device-1',
        ),
        uploadTasks: uploadTasks,
        uploads: uploads,
        payloadPreparer: const FakeUploadPayloadPreparer(
          bytes: [1, 2, 3, 4, 5, 6, 7],
        ),
        objectIdForTask: (_) => 'object-1',
        versionIdForTask: (_) => 'version-1',
        chunkSize: 3,
      );

      final result = await executor.executePendingUploads();

      expect(result.uploadedCount, 1);
      expect(uploads.uploadedPartIndexes, [0, 1, 2]);
      expect(uploads.uploadedParts, [
        [1, 2, 3],
        [4, 5, 6],
        [7],
      ]);
    },
  );

  test('executePendingUploads resumes existing upload session', () async {
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 7,
        modifiedAt: DateTime.utc(2026, 6, 27, 9),
        status: 'failed',
        attempts: 1,
        createdAt: DateTime.utc(2026, 6, 27, 10),
        uploadSessionId: 'session-resume',
        uploadPayloadHash:
            '32bbe378a25091502b2baf9f7258c19444e7a43ee4593b08030acd790bd66e6a',
        uploadTotalSize: 7,
        uploadChunkSize: 3,
        uploadedBytes: 3,
      ),
    ]);
    final uploads = FakeUploadGateway(
      existingSession: const UploadSession(
        id: 'session-resume',
        status: 'pending',
        totalSize: 7,
        chunkSize: 3,
        receivedSize: 3,
      ),
    );
    final executor = LocalUploadExecutor(
      sessionStore: FakeSessionStore(
        token: 'server-token',
        deviceId: 'device-1',
      ),
      uploadTasks: uploadTasks,
      uploads: uploads,
      payloadPreparer: const FakeUploadPayloadPreparer(
        bytes: [1, 2, 3, 4, 5, 6, 7],
      ),
      objectIdForTask: (_) => 'object-1',
      versionIdForTask: (_) => 'version-1',
      chunkSize: 3,
    );

    final result = await executor.executePendingUploads();

    expect(result.uploadedCount, 1);
    expect(uploads.createCount, 0);
    expect(uploads.requestedSessionId, 'session-resume');
    expect(uploads.uploadedPartIndexes, [1, 2]);
    expect(uploads.uploadedParts, [
      [4, 5, 6],
      [7],
    ]);
    expect(uploadTasks.saved.single.status, 'uploaded');
    expect(uploadTasks.saved.single.uploadedBytes, 7);
  });

  test('executePendingUploads can upload one sync root only', () async {
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
      LocalUploadTask(
        id: 'root-2:b.jpg',
        syncRootId: 'root-2',
        localPath: '/Users/alice/Docs/b.jpg',
        relativePath: 'b.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
    ]);
    final uploads = FakeUploadGateway();
    final executor = LocalUploadExecutor(
      sessionStore: FakeSessionStore(
        token: 'server-token',
        deviceId: 'device-1',
      ),
      uploadTasks: uploadTasks,
      uploads: uploads,
      payloadPreparer: const FakeUploadPayloadPreparer(),
      objectIdForTask: (_) => 'object-1',
      versionIdForTask: (_) => 'version-1',
      chunkSize: 3,
    );

    final result = await executor.executePendingUploads(syncRootId: 'root-2');

    expect(result.uploadedCount, 1);
    expect(uploads.createdSyncRootId, 'root-2');
    expect(uploadTasks.saved.map((task) => task.status), [
      'pending',
      'uploaded',
    ]);
  });

  test('executePendingUploads marks failed task and continues', () async {
    final uploadTasks = FakeUploadTaskStore([
      LocalUploadTask(
        id: 'root-1:a.jpg',
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27, 9),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 6, 27, 10),
      ),
    ]);
    final executor = LocalUploadExecutor(
      sessionStore: FakeSessionStore(
        token: 'server-token',
        deviceId: 'device-1',
      ),
      uploadTasks: uploadTasks,
      uploads: ThrowingUploadGateway(Exception('网络暂时不可用')),
      payloadPreparer: const FakeUploadPayloadPreparer(),
      objectIdForTask: (_) => 'object-1',
      versionIdForTask: (_) => 'version-1',
      chunkSize: 3,
    );

    final result = await executor.executePendingUploads();

    expect(result.uploadedCount, 0);
    expect(result.failedCount, 1);
    expect(uploadTasks.saved.single.status, 'failed');
    expect(uploadTasks.saved.single.attempts, 1);
    expect(uploadTasks.saved.single.lastError, '网络暂时不可用');
  });
}

class FakeSessionStore implements SessionStore {
  final String? token;
  final String? deviceId;

  const FakeSessionStore({this.token, this.deviceId});

  @override
  Future<String?> loadAuthToken() async => token;

  @override
  Future<String?> loadAuthExpiresAt() async => '2999-01-01T00:00:00Z';

  @override
  Future<String?> loadDeviceId() async => deviceId;

  @override
  Future<void> saveAuthSession(session) async {}

  @override
  Future<void> saveDevice(device) async {}
}

class FakeUploadTaskStore implements UploadTaskStore {
  List<LocalUploadTask> saved;

  FakeUploadTaskStore(this.saved);

  @override
  Future<List<LocalUploadTask>> loadUploadTasks() async => saved;

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {
    saved = tasks;
  }
}

class FakeUploadPayloadPreparer implements UploadPayloadPreparer {
  final List<int> bytes;

  const FakeUploadPayloadPreparer({this.bytes = const [1, 2, 3]});

  @override
  Future<PreparedUploadPayload> prepare(
    LocalUploadTask task, {
    required String objectId,
    required String versionId,
  }) async {
    expect(objectId, 'object-1');
    expect(versionId, 'version-1');
    return PreparedUploadPayload(
      bytes: bytes,
      encryptedName: 'enc:a.jpg',
      metadataJson: '{"relative_path":"a.jpg"}',
    );
  }
}

class FakePostUploadCleaner implements LocalPostUploadCleaner {
  int callCount = 0;

  @override
  Future<Object> cleanupUploadedTasks() async {
    callCount += 1;
    return Object();
  }
}

class FakeUploadGateway implements UploadGateway {
  final UploadSession? existingSession;
  String? createdSyncRootId;
  String? requestedSessionId;
  var createCount = 0;
  final uploadedPartIndexes = <int>[];
  final uploadedParts = <List<int>>[];

  FakeUploadGateway({this.existingSession});

  @override
  Future<UploadSession> createUploadSession({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
    required String versionId,
    required int totalSize,
    required int chunkSize,
    required String encryptedName,
    required String metadataJson,
  }) async {
    createCount += 1;
    createdSyncRootId = syncRootId;
    return UploadSession(
      id: 'session-1',
      status: 'pending',
      totalSize: totalSize,
      chunkSize: chunkSize,
      receivedSize: 0,
    );
  }

  @override
  Future<UploadSession> getUploadSession({
    required String token,
    required String sessionId,
  }) async {
    requestedSessionId = sessionId;
    return existingSession ??
        const UploadSession(id: 'session-missing', status: 'pending');
  }

  @override
  Future<void> uploadPart({
    required String token,
    required String sessionId,
    required int partIndex,
    required List<int> bytes,
  }) async {
    uploadedPartIndexes.add(partIndex);
    uploadedParts.add(bytes);
  }

  @override
  Future<UploadedFileVersion> completeUploadSession({
    required String token,
    required String sessionId,
  }) async {
    return const UploadedFileVersion(id: 'version-1');
  }
}

class ThrowingUploadGateway implements UploadGateway {
  final Object error;

  const ThrowingUploadGateway(this.error);

  @override
  Future<UploadSession> createUploadSession({
    required String token,
    required String deviceId,
    required String syncRootId,
    required String objectId,
    required String versionId,
    required int totalSize,
    required int chunkSize,
    required String encryptedName,
    required String metadataJson,
  }) async {
    throw error;
  }

  @override
  Future<UploadSession> getUploadSession({
    required String token,
    required String sessionId,
  }) async {
    throw error;
  }

  @override
  Future<void> uploadPart({
    required String token,
    required String sessionId,
    required int partIndex,
    required List<int> bytes,
  }) async {}

  @override
  Future<UploadedFileVersion> completeUploadSession({
    required String token,
    required String sessionId,
  }) async {
    throw UnimplementedError();
  }
}
