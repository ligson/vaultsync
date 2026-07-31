import 'dart:typed_data';

import '../download/download_service.dart';
import '../sync/encrypted_download_payload_decrypter.dart';
import '../sync/sync_models.dart';

enum RemoteFilePreviewKind { image, video, pdf, text }

RemoteFilePreviewKind? remoteFilePreviewKindFor(String fileName) {
  final dotIndex = fileName.lastIndexOf('.');
  final extension = dotIndex < 0
      ? ''
      : fileName.substring(dotIndex + 1).toLowerCase();
  if (_imageExtensions.contains(extension)) {
    return RemoteFilePreviewKind.image;
  }
  if (_videoExtensions.contains(extension)) {
    return RemoteFilePreviewKind.video;
  }
  if (extension == 'pdf') {
    return RemoteFilePreviewKind.pdf;
  }
  if (_textExtensions.contains(extension)) {
    return RemoteFilePreviewKind.text;
  }
  return null;
}

const _imageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
};

const _videoExtensions = {'mp4', 'm4v', 'mov', 'webm', 'avi', 'mkv'};

const _textExtensions = {
  'txt',
  'md',
  'markdown',
  'json',
  'yaml',
  'yml',
  'xml',
  'csv',
  'log',
  'ini',
  'conf',
  'sql',
  'dart',
  'go',
  'js',
  'ts',
  'jsx',
  'tsx',
  'css',
  'html',
  'htm',
  'sh',
};

class RemoteFilePreviewData {
  final String name;
  final RemoteFilePreviewKind kind;
  final Uint8List bytes;

  const RemoteFilePreviewData({
    required this.name,
    required this.kind,
    required this.bytes,
  });
}

abstract interface class RemoteFilePreviewGateway {
  Future<RemoteFilePreviewData> load({
    required String token,
    required RemoteBackupEntry entry,
  });
}

class RemoteFilePreviewLoader implements RemoteFilePreviewGateway {
  static const _maxImageBytes = 64 * 1024 * 1024;
  static const _maxVideoBytes = 256 * 1024 * 1024;
  static const _maxPdfBytes = 128 * 1024 * 1024;
  static const _maxTextBytes = 5 * 1024 * 1024;

  final DownloadGateway downloads;
  final DownloadPayloadDecrypter decrypter;

  const RemoteFilePreviewLoader({
    required this.downloads,
    required this.decrypter,
  });

  @override
  Future<RemoteFilePreviewData> load({
    required String token,
    required RemoteBackupEntry entry,
  }) async {
    if (!entry.decryptable) {
      throw Exception('此文件的元数据无法解密，不能预览');
    }
    final kind = remoteFilePreviewKindFor(entry.name);
    if (kind == null) {
      throw Exception('暂不支持预览此文件格式');
    }
    final maxBytes = _maxBytesFor(kind);
    if (entry.sizeBytes > maxBytes) {
      throw Exception('文件过大，在线预览上限为 ${_formatLimit(maxBytes)}');
    }
    if (entry.encryptedName.isEmpty || entry.metadataJson.isEmpty) {
      throw Exception('服务器未返回完整文件信息，暂时无法预览');
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
    if (decrypted.bytes.length > maxBytes) {
      throw Exception('文件过大，在线预览上限为 ${_formatLimit(maxBytes)}');
    }
    return RemoteFilePreviewData(
      name: decrypted.name,
      kind: kind,
      bytes: Uint8List.fromList(decrypted.bytes),
    );
  }

  int _maxBytesFor(RemoteFilePreviewKind kind) {
    return switch (kind) {
      RemoteFilePreviewKind.image => _maxImageBytes,
      RemoteFilePreviewKind.video => _maxVideoBytes,
      RemoteFilePreviewKind.pdf => _maxPdfBytes,
      RemoteFilePreviewKind.text => _maxTextBytes,
    };
  }

  String _formatLimit(int bytes) => '${bytes ~/ (1024 * 1024)} MB';
}
