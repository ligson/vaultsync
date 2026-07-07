import 'package:crypto/crypto.dart';

import '../../core/storage/app_storage.dart';
import '../download/download_service.dart';
import 'encrypted_download_payload_decrypter.dart';
import 'local_download_writer.dart';
import 'local_remote_delete_handler.dart';
import 'sync_models.dart';
import 'sync_service.dart';

class SyncPullResult {
  final int downloadedCount;
  final int deleteCount;
  final int blockedDeleteCount;
  final int nextCursor;
  final bool hasMore;

  const SyncPullResult({
    required this.downloadedCount,
    required this.deleteCount,
    this.blockedDeleteCount = 0,
    required this.nextCursor,
    required this.hasMore,
  });
}

abstract interface class RemoteSyncPullGateway {
  Future<SyncPullResult> pullRemoteChanges();
}

class SyncPullExecutor implements RemoteSyncPullGateway {
  final SessionStore sessionStore;
  final SyncCursorStore cursorStore;
  final SyncChangeGateway changes;
  final DownloadGateway downloads;
  final DownloadPayloadDecrypter decrypter;
  final RemoteObjectWriter writer;
  final RemoteDeleteHandler deleteHandler;
  final int limit;

  const SyncPullExecutor({
    required this.sessionStore,
    required this.cursorStore,
    required this.changes,
    required this.downloads,
    required this.decrypter,
    required this.writer,
    required this.deleteHandler,
    this.limit = 100,
  });

  @override
  Future<SyncPullResult> pullRemoteChanges() async {
    final token = await sessionStore.loadAuthToken();
    final deviceId = await sessionStore.loadDeviceId();
    if (token == null || token.isEmpty) {
      throw Exception('登录状态已失效');
    }
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('设备状态已失效');
    }

    final cursor = await cursorStore.loadRemoteCursor();
    final page = await changes.listChanges(
      token: token,
      deviceId: deviceId,
      cursor: cursor,
      limit: limit,
    );

    var downloadedCount = 0;
    var deleteCount = 0;
    var blockedDeleteCount = 0;
    for (final item in page.items) {
      if (item.changeType == 'upsert' && item.versionId.isNotEmpty) {
        final object = await downloads.downloadCiphertext(
          token: token,
          versionId: item.versionId,
          objectId: item.objectId,
          syncRootId: item.syncRootId,
          encryptedName: item.encryptedName,
        );
        _verifyDownloadedObject(item, object.bytes);
        final decrypted = await decrypter.decrypt(
          syncRootId: item.syncRootId,
          objectId: item.objectId,
          versionId: item.versionId,
          encryptedName: item.encryptedName,
          metadataJson: item.metadataJson,
          payloadBytes: object.bytes,
        );
        await writer.writeRemoteObject(
          syncRootId: item.syncRootId,
          objectId: item.objectId,
          versionId: item.versionId,
          object: decrypted,
        );
        downloadedCount += 1;
      } else if (item.changeType == 'delete') {
        final deleteResult = await deleteHandler.handleRemoteDelete(
          syncRootId: item.syncRootId,
          objectId: item.objectId,
        );
        deleteCount += 1;
        if (deleteResult.blockedLocalChange) {
          blockedDeleteCount += 1;
        }
      }
    }

    await cursorStore.saveRemoteCursor(page.nextCursor);
    return SyncPullResult(
      downloadedCount: downloadedCount,
      deleteCount: deleteCount,
      blockedDeleteCount: blockedDeleteCount,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
    );
  }

  void _verifyDownloadedObject(SyncChangeItem item, List<int> bytes) {
    if (item.sizeBytes > 0 && bytes.length != item.sizeBytes) {
      throw Exception('密文大小校验失败');
    }
    if (item.contentHash.isNotEmpty) {
      final actualHash = sha256.convert(bytes).toString();
      if (actualHash != item.contentHash) {
        throw Exception('密文哈希校验失败');
      }
    }
  }
}
