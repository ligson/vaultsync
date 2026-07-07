import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/download/download_models.dart';
import 'package:vaultsync_app/features/download/download_service.dart';
import 'package:vaultsync_app/features/sync/encrypted_download_payload_decrypter.dart';
import 'package:vaultsync_app/features/sync/local_download_writer.dart';
import 'package:vaultsync_app/features/sync/local_remote_delete_handler.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/sync_pull_executor.dart';
import 'package:vaultsync_app/features/sync/sync_service.dart';

void main() {
  test('pullRemoteChanges downloads upserts and saves next cursor', () async {
    final cursorStore = FakeSyncCursorStore(cursor: 7);
    final changes = FakeSyncChangeGateway(
      page: SyncChangePage(
        items: [
          SyncChangeItem(
            id: 'version-1',
            changeType: 'upsert',
            versionId: 'version-1',
            objectId: 'object-1',
            syncRootId: 'root-1',
            cursorValue: 8,
            encryptedName: 'vaultsync-name:v1:name',
            contentHash: sha256.convert([1, 2, 3]).toString(),
            sizeBytes: 3,
            metadataJson: '{"nonce":"abc"}',
            createdAt: '2026-06-27T01:00:00Z',
          ),
          SyncChangeItem(
            id: '9',
            changeType: 'delete',
            versionId: '',
            objectId: 'object-2',
            syncRootId: 'root-1',
            cursorValue: 9,
            encryptedName: '',
            contentHash: '',
            sizeBytes: 0,
            metadataJson: '',
            createdAt: '2026-06-27T01:01:00Z',
          ),
        ],
        nextCursor: 9,
        hasMore: false,
      ),
    );
    final downloads = FakeDownloadGateway();
    final decrypter = FakeDownloadPayloadDecrypter();
    final writer = FakeRemoteObjectWriter();
    final deleteHandler = FakeRemoteDeleteHandler();
    final executor = SyncPullExecutor(
      sessionStore: const FakeSessionStore(
        token: 'server-token',
        deviceId: 'device-1',
      ),
      cursorStore: cursorStore,
      changes: changes,
      downloads: downloads,
      decrypter: decrypter,
      writer: writer,
      deleteHandler: deleteHandler,
    );

    final result = await executor.pullRemoteChanges();

    expect(changes.token, 'server-token');
    expect(changes.deviceId, 'device-1');
    expect(changes.cursor, 7);
    expect(downloads.downloadedVersionIds, ['version-1']);
    expect(downloads.encryptedNames, ['vaultsync-name:v1:name']);
    expect(decrypter.decryptedVersionIds, ['version-1']);
    expect(decrypter.metadataJsonItems, ['{"nonce":"abc"}']);
    expect(writer.writtenRelativePaths, ['photos/a.jpg']);
    expect(deleteHandler.deletedObjectIds, ['object-2']);
    expect(result.downloadedCount, 1);
    expect(result.deleteCount, 1);
    expect(result.nextCursor, 9);
    expect(cursorStore.savedCursor, 9);
  });

  test(
    'pullRemoteChanges rejects downloaded ciphertext hash mismatch',
    () async {
      final cursorStore = FakeSyncCursorStore(cursor: 7);
      final executor = SyncPullExecutor(
        sessionStore: const FakeSessionStore(
          token: 'server-token',
          deviceId: 'device-1',
        ),
        cursorStore: cursorStore,
        changes: FakeSyncChangeGateway(
          page: const SyncChangePage(
            items: [
              SyncChangeItem(
                id: 'version-1',
                changeType: 'upsert',
                versionId: 'version-1',
                objectId: 'object-1',
                syncRootId: 'root-1',
                cursorValue: 8,
                encryptedName: 'vaultsync-name:v1:name',
                contentHash: 'wrong-hash',
                sizeBytes: 3,
                metadataJson: '{"nonce":"abc"}',
                createdAt: '2026-06-27T01:00:00Z',
              ),
            ],
            nextCursor: 8,
            hasMore: false,
          ),
        ),
        downloads: FakeDownloadGateway(),
        decrypter: FakeDownloadPayloadDecrypter(),
        writer: FakeRemoteObjectWriter(),
        deleteHandler: FakeRemoteDeleteHandler(),
      );

      expect(
        () => executor.pullRemoteChanges(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('密文哈希校验失败'),
          ),
        ),
      );
      expect(cursorStore.savedCursor, isNull);
    },
  );

  test('pullRemoteChanges reports delete blocked by local changes', () async {
    final cursorStore = FakeSyncCursorStore(cursor: 7);
    final executor = SyncPullExecutor(
      sessionStore: const FakeSessionStore(
        token: 'server-token',
        deviceId: 'device-1',
      ),
      cursorStore: cursorStore,
      changes: FakeSyncChangeGateway(
        page: const SyncChangePage(
          items: [
            SyncChangeItem(
              id: '8',
              changeType: 'delete',
              versionId: '',
              objectId: 'object-1',
              syncRootId: 'root-1',
              cursorValue: 8,
              encryptedName: '',
              contentHash: '',
              sizeBytes: 0,
              metadataJson: '',
              createdAt: '2026-06-27T01:00:00Z',
            ),
          ],
          nextCursor: 8,
          hasMore: false,
        ),
      ),
      downloads: FakeDownloadGateway(),
      decrypter: FakeDownloadPayloadDecrypter(),
      writer: FakeRemoteObjectWriter(),
      deleteHandler: FakeRemoteDeleteHandler(
        result: const RemoteDeleteResult(
          deleted: false,
          blockedLocalChange: true,
        ),
      ),
    );

    final result = await executor.pullRemoteChanges();

    expect(result.deleteCount, 1);
    expect(result.blockedDeleteCount, 1);
    expect(cursorStore.savedCursor, 8);
  });
}

class FakeDownloadPayloadDecrypter implements DownloadPayloadDecrypter {
  final List<String> decryptedVersionIds = [];
  final List<String> metadataJsonItems = [];

  @override
  Future<DecryptedRemoteObject> decrypt({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required String encryptedName,
    required String metadataJson,
    required List<int> payloadBytes,
  }) async {
    decryptedVersionIds.add(versionId);
    metadataJsonItems.add(metadataJson);
    return DecryptedRemoteObject(
      name: 'a.jpg',
      relativePath: 'photos/a.jpg',
      metadata: const {'relative_path': 'photos/a.jpg'},
      bytes: payloadBytes,
    );
  }
}

class FakeRemoteObjectWriter implements RemoteObjectWriter {
  final List<String> writtenRelativePaths = [];

  @override
  Future<LocalDownloadWriteResult> writeRemoteObject({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required DecryptedRemoteObject object,
  }) async {
    writtenRelativePaths.add(object.relativePath);
    return LocalDownloadWriteResult(localPath: '/local/${object.relativePath}');
  }
}

class FakeRemoteDeleteHandler implements RemoteDeleteHandler {
  final RemoteDeleteResult result;
  final List<String> deletedObjectIds = [];

  FakeRemoteDeleteHandler({
    this.result = const RemoteDeleteResult(
      deleted: true,
      blockedLocalChange: false,
    ),
  });

  @override
  Future<RemoteDeleteResult> handleRemoteDelete({
    required String syncRootId,
    required String objectId,
  }) async {
    deletedObjectIds.add(objectId);
    return result;
  }
}

class FakeSessionStore implements SessionStore {
  final String? token;
  final String? deviceId;

  const FakeSessionStore({required this.token, required this.deviceId});

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

class FakeSyncCursorStore implements SyncCursorStore {
  final int cursor;
  int? savedCursor;

  FakeSyncCursorStore({required this.cursor});

  @override
  Future<int> loadRemoteCursor() async => cursor;

  @override
  Future<void> saveRemoteCursor(int cursor) async {
    savedCursor = cursor;
  }
}

class FakeSyncChangeGateway implements SyncChangeGateway {
  final SyncChangePage page;
  String? token;
  String? deviceId;
  int? cursor;

  FakeSyncChangeGateway({required this.page});

  @override
  Future<SyncChangePage> listChanges({
    required String token,
    required String deviceId,
    required int cursor,
    int limit = 100,
  }) async {
    this.token = token;
    this.deviceId = deviceId;
    this.cursor = cursor;
    return page;
  }
}

class FakeDownloadGateway implements DownloadGateway {
  final List<String> downloadedVersionIds = [];
  final List<String> encryptedNames = [];

  @override
  Future<DownloadedObject> downloadCiphertext({
    required String token,
    required String versionId,
    required String objectId,
    required String syncRootId,
    required String encryptedName,
  }) async {
    downloadedVersionIds.add(versionId);
    encryptedNames.add(encryptedName);
    return DownloadedObject(
      versionId: versionId,
      objectId: objectId,
      syncRootId: syncRootId,
      encryptedName: encryptedName,
      bytes: const [1, 2, 3],
    );
  }
}
