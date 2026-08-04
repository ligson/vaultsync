import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../sync/encrypted_download_payload_decrypter.dart';
import '../sync/sync_models.dart';
import 'download_service.dart';

class RemoteFileDownloadData {
  final String name;
  final List<int> bytes;

  const RemoteFileDownloadData({required this.name, required this.bytes});
}

abstract interface class RemoteFileDownloadGateway {
  Future<RemoteFileDownloadData> load({
    required String token,
    required RemoteBackupEntry entry,
  });
}

class RemoteFileDownloadLoader implements RemoteFileDownloadGateway {
  final DownloadGateway downloads;
  final DownloadPayloadDecrypter decrypter;

  const RemoteFileDownloadLoader({
    required this.downloads,
    required this.decrypter,
  });

  @override
  Future<RemoteFileDownloadData> load({
    required String token,
    required RemoteBackupEntry entry,
  }) async {
    if (!entry.decryptable) {
      throw Exception('此文件的元数据无法解密，不能下载');
    }
    if (entry.encryptedName.isEmpty || entry.metadataJson.isEmpty) {
      throw Exception('服务器未返回完整文件信息，暂时无法下载');
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
    return RemoteFileDownloadData(name: decrypted.name, bytes: decrypted.bytes);
  }
}

class RemoteFileSaveTarget {
  final String path;
  final String displayPath;

  const RemoteFileSaveTarget({required this.path, required this.displayPath});
}

abstract interface class RemoteFileSaveGateway {
  Future<RemoteFileSaveTarget?> chooseTarget({
    required String fileName,
    required String platform,
  });

  Future<void> write({
    required RemoteFileSaveTarget target,
    required List<int> bytes,
  });
}

class PlatformRemoteFileSaveGateway implements RemoteFileSaveGateway {
  const PlatformRemoteFileSaveGateway();

  @override
  Future<RemoteFileSaveTarget?> chooseTarget({
    required String fileName,
    required String platform,
  }) async {
    final safeName = _safeFileName(fileName);
    if (platform == 'ios') {
      final documents = await getApplicationDocumentsDirectory();
      final directory = Directory(
        '${documents.path}${Platform.pathSeparator}VaultSync Downloads',
      );
      await directory.create(recursive: true);
      final path = await _availablePath(directory.path, safeName);
      return RemoteFileSaveTarget(
        path: path,
        displayPath: '文件 App/VaultSync Downloads/${_baseName(path)}',
      );
    }
    if (platform == 'android') {
      final directoryPath = await getDirectoryPath(confirmButtonText: '保存到此目录');
      if (directoryPath == null || directoryPath.isEmpty) {
        return null;
      }
      final path = await _availablePath(directoryPath, safeName);
      return RemoteFileSaveTarget(path: path, displayPath: path);
    }
    final location = await getSaveLocation(
      suggestedName: safeName,
      confirmButtonText: '保存',
    );
    if (location == null) {
      return null;
    }
    return RemoteFileSaveTarget(
      path: location.path,
      displayPath: location.path,
    );
  }

  @override
  Future<void> write({
    required RemoteFileSaveTarget target,
    required List<int> bytes,
  }) async {
    final file = File(target.path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<String> _availablePath(String directory, String fileName) async {
    final separator = Platform.pathSeparator;
    final dotIndex = fileName.lastIndexOf('.');
    final hasExtension = dotIndex > 0 && dotIndex < fileName.length - 1;
    final stem = hasExtension ? fileName.substring(0, dotIndex) : fileName;
    final extension = hasExtension ? fileName.substring(dotIndex) : '';
    var candidate = '$directory$separator$fileName';
    var suffix = 1;
    while (await File(candidate).exists()) {
      candidate = '$directory$separator$stem ($suffix)$extension';
      suffix += 1;
    }
    return candidate;
  }

  String _safeFileName(String value) {
    final segments = value.trim().split(RegExp(r'[/\\]'));
    final lastSegment = segments.isEmpty ? '' : segments.last;
    final sanitized = lastSegment
        .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
        .trim();
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      return 'VaultSync 下载文件';
    }
    return sanitized;
  }

  String _baseName(String path) {
    final segments = path.split(RegExp(r'[/\\]'));
    return segments.isEmpty ? path : segments.last;
  }
}
