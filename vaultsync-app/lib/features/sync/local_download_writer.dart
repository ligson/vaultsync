import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/storage/app_storage.dart';
import 'encrypted_download_payload_decrypter.dart';
import 'sync_models.dart';

class LocalDownloadWriteResult {
  final String localPath;
  final bool conflicted;

  const LocalDownloadWriteResult({
    required this.localPath,
    this.conflicted = false,
  });
}

abstract interface class RemoteObjectWriter {
  Future<LocalDownloadWriteResult> writeRemoteObject({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required DecryptedRemoteObject object,
  });
}

class LocalDownloadWriter implements RemoteObjectWriter {
  final SyncRootMappingStore mappings;
  final RemoteVersionIndexStore remoteVersions;
  final SyncIssueStore? syncIssues;
  final String conflictDeviceName;
  final DateTime Function() now;

  LocalDownloadWriter({
    required this.mappings,
    required this.remoteVersions,
    this.syncIssues,
    this.conflictDeviceName = 'device',
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  @override
  Future<LocalDownloadWriteResult> writeRemoteObject({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required DecryptedRemoteObject object,
  }) async {
    final mapping = await _mappingFor(syncRootId);
    final relativePath = _safeRelativePath(object.relativePath);
    var localPath = [
      mapping.localPath,
      ...relativePath.split('/'),
    ].join(Platform.pathSeparator);
    var conflicted = false;
    final existingFile = File(localPath);
    final existingIndex = await _indexFor(syncRootId, objectId);
    if (await existingFile.exists() &&
        !await _matchesRemoteIndex(existingFile, existingIndex)) {
      localPath = await _availableConflictPath(localPath);
      conflicted = true;
    }
    final file = File(localPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(object.bytes, flush: true);
    final contentHash = sha256.convert(object.bytes).toString();
    await remoteVersions.saveRemoteVersionIndex(
      LocalRemoteVersionIndex(
        syncRootId: syncRootId,
        objectId: objectId,
        versionId: versionId,
        relativePath: relativePath,
        localPath: file.path,
        contentHash: contentHash,
      ),
    );
    if (conflicted) {
      await syncIssues?.saveSyncIssue(
        LocalSyncIssue(
          id: 'download_conflict:$syncRootId:$objectId',
          type: 'download_conflict',
          syncRootId: syncRootId,
          objectId: objectId,
          versionId: versionId,
          relativePath: relativePath,
          localPath: file.path,
          message: '远端更新已保存为冲突副本',
          status: 'open',
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }
    return LocalDownloadWriteResult(
      localPath: file.path,
      conflicted: conflicted,
    );
  }

  Future<LocalSyncRootMapping> _mappingFor(String syncRootId) async {
    final items = await mappings.loadSyncRootMappings();
    for (final item in items) {
      if (item.syncRootId == syncRootId) {
        return item;
      }
    }
    throw Exception('本地同步目录不存在');
  }

  String _safeRelativePath(String relativePath) {
    final normalized = relativePath.replaceAll('\\', '/');
    if (normalized.trim().isEmpty || normalized.startsWith('/')) {
      throw Exception('远端路径无效');
    }
    final segments = normalized.split('/');
    if (segments.any((segment) {
      return segment.isEmpty || segment == '.' || segment == '..';
    })) {
      throw Exception('远端路径无效');
    }
    return segments.join('/');
  }

  Future<LocalRemoteVersionIndex?> _indexFor(
    String syncRootId,
    String objectId,
  ) async {
    final entries = await remoteVersions.loadRemoteVersionIndexes();
    for (final entry in entries) {
      if (entry.syncRootId == syncRootId && entry.objectId == objectId) {
        return entry;
      }
    }
    return null;
  }

  Future<bool> _matchesRemoteIndex(
    File file,
    LocalRemoteVersionIndex? index,
  ) async {
    if (index == null) {
      return false;
    }
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString() == index.contentHash;
  }

  Future<String> _availableConflictPath(String originalPath) async {
    final normalized = originalPath.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final dir = slash < 0 ? '' : originalPath.substring(0, slash);
    final name = slash < 0 ? originalPath : originalPath.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    final ext = dot <= 0 ? '' : name.substring(dot);
    final deviceName = _safeConflictSegment(conflictDeviceName);
    final timestamp = _conflictTimestamp(now().toUtc());
    var index = 0;
    while (true) {
      final indexSuffix = index == 0 ? '' : ' $index';
      final candidateName =
          '$stem (conflict $deviceName $timestamp$indexSuffix)$ext';
      final candidate = dir.isEmpty
          ? candidateName
          : '$dir${Platform.pathSeparator}$candidateName';
      if (!await File(candidate).exists()) {
        return candidate;
      }
      index += 1;
    }
  }

  String _safeConflictSegment(String value) {
    final normalized = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalized.isEmpty ? 'device' : normalized;
  }

  String _conflictTimestamp(DateTime value) {
    String two(int item) => item.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }
}
