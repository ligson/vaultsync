import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' as crypto;

import '../../core/storage/app_storage.dart';
import '../download/download_service.dart';
import '../sync/encrypted_download_payload_decrypter.dart';
import '../sync/sync_models.dart';
import '../sync/wechat_dat_decoder.dart';
import 'remote_file_preview.dart';

typedef RemoteThumbnailCacheDirectoryProvider = Future<Directory> Function();
typedef RemoteThumbnailEncoder = Future<Uint8List?> Function(Uint8List bytes);

abstract interface class RemoteFileThumbnailGateway {
  Future<Uint8List?> load(RemoteBackupEntry entry);
}

class CachedRemoteFileThumbnailLoader implements RemoteFileThumbnailGateway {
  static const _maxSourceBytes = 4 * 1024 * 1024;
  static const _targetWidth = 360;
  static const _maxConcurrentLoads = 3;

  final SessionStore sessionStore;
  final DownloadGateway downloads;
  final DownloadPayloadDecrypter decrypter;
  final RemoteThumbnailCacheDirectoryProvider cacheDirectoryProvider;
  final RemoteThumbnailEncoder thumbnailEncoder;
  final WechatDatV2ImageKeyProvider? wechatDatV2ImageKeys;

  final Map<String, Future<Uint8List?>> _inFlight = {};
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  var _activeLoads = 0;

  CachedRemoteFileThumbnailLoader({
    required this.sessionStore,
    required this.downloads,
    required this.decrypter,
    required this.cacheDirectoryProvider,
    this.wechatDatV2ImageKeys,
    RemoteThumbnailEncoder? thumbnailEncoder,
  }) : thumbnailEncoder = thumbnailEncoder ?? _resizeImage;

  @override
  Future<Uint8List?> load(RemoteBackupEntry entry) {
    if (!entry.decryptable ||
        (!remoteFileCanProbeContent(entry) &&
            remoteFilePreviewKindFor(entry.name) !=
                RemoteFilePreviewKind.image &&
            remoteFilePreviewKindFor(entry.relativePath) !=
                RemoteFilePreviewKind.image) ||
        entry.sizeBytes <= 0 ||
        entry.sizeBytes > _maxSourceBytes ||
        entry.encryptedName.isEmpty ||
        entry.metadataJson.isEmpty) {
      return Future.value(null);
    }
    final key = _cacheKey(entry);
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _withLoadSlot(() => _loadAndCache(entry, key));
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  Future<Uint8List?> _loadAndCache(RemoteBackupEntry entry, String key) async {
    final directory = await cacheDirectoryProvider();
    await directory.create(recursive: true);
    final cacheFile = File(
      '${directory.path}${Platform.pathSeparator}$key.png',
    );
    try {
      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (bytes.isNotEmpty) {
          return bytes;
        }
      }
    } catch (_) {
      // 缓存损坏或读取失败时继续重新生成，不影响文件列表展示。
    }

    final token = await sessionStore.loadAuthToken();
    if (token == null || token.isEmpty) {
      return null;
    }
    final downloaded = await downloads.downloadCiphertext(
      token: token,
      versionId: entry.versionId,
      objectId: entry.objectId,
      syncRootId: entry.syncRootId,
      encryptedName: entry.encryptedName,
    );
    final decrypted = await decrypter.decrypt(
      syncRootId: entry.syncRootId,
      objectId: entry.objectId,
      versionId: entry.versionId,
      encryptedName: entry.encryptedName,
      metadataJson: entry.metadataJson,
      payloadBytes: downloaded.bytes,
    );
    final resolved = resolveRemoteFilePreviewContent(
      name: decrypted.name,
      relativePath: decrypted.relativePath,
      bytes: decrypted.bytes,
      wechatDatV2ImageKey: await _wechatDatV2ImageKey(
        name: decrypted.name,
        relativePath: decrypted.relativePath,
        bytes: decrypted.bytes,
      ),
    );
    if (resolved?.kind != RemoteFilePreviewKind.image) {
      return null;
    }
    final thumbnail = await thumbnailEncoder(resolved!.bytes);
    if (thumbnail == null || thumbnail.isEmpty) {
      return null;
    }
    try {
      final partFile = File('${cacheFile.path}.part');
      await partFile.writeAsBytes(thumbnail, flush: true);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
      await partFile.rename(cacheFile.path);
    } catch (_) {
      // 缩略图缓存失败不影响本次展示。
    }
    return thumbnail;
  }

  Future<T> _withLoadSlot<T>(Future<T> Function() body) async {
    if (_activeLoads >= _maxConcurrentLoads) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _activeLoads += 1;
    try {
      return await body();
    } finally {
      _activeLoads -= 1;
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      }
    }
  }

  static Future<Uint8List?> _resizeImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _targetWidth,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  String _cacheKey(RemoteBackupEntry entry) {
    final raw = [
      entry.syncRootId,
      entry.objectId,
      entry.versionId,
      entry.contentHash,
      entry.clientContentHash,
      entry.sizeBytes.toString(),
    ].join('|');
    return crypto.sha256.convert(raw.codeUnits).toString();
  }

  Future<WechatDatV2ImageKey?> _wechatDatV2ImageKey({
    required String name,
    required String relativePath,
    required List<int> bytes,
  }) {
    if (!looksLikeWechatDatV2Container(bytes)) {
      return Future.value(null);
    }
    return wechatDatV2ImageKeys?.loadImageKey(
          name: name,
          relativePath: relativePath,
          bytes: bytes,
        ) ??
        Future.value(null);
  }
}
