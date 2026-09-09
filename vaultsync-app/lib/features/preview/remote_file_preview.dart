import 'dart:typed_data';

import '../download/download_service.dart';
import '../sync/encrypted_download_payload_decrypter.dart';
import '../sync/local_sync_scanner.dart';
import '../sync/sync_models.dart';
import '../sync/wechat_dat_decoder.dart';

enum RemoteFilePreviewKind { image, video, pdf, text }

class RemoteVideoFileDiagnosis {
  final bool isMp4Container;
  final bool hasMovieIndex;
  final bool hasMediaData;
  final String? videoCodec;

  const RemoteVideoFileDiagnosis({
    required this.isMp4Container,
    required this.hasMovieIndex,
    required this.hasMediaData,
    required this.videoCodec,
  });

  bool get isLikelyComplete => isMp4Container && hasMovieIndex && hasMediaData;

  String get codecLabel => switch (videoCodec) {
    'hvc1' || 'hev1' => 'H.265 / HEVC',
    'avc1' || 'avc3' => 'H.264 / AVC',
    'av01' => 'AV1',
    'vp09' => 'VP9',
    'vp08' => 'VP8',
    'mp4v' => 'MPEG-4 Visual',
    _ => videoCodec == null ? '未知视频编码' : videoCodec!,
  };
}

RemoteVideoFileDiagnosis diagnoseRemoteVideoBytes(List<int> bytes) {
  final isMp4 = _asciiAt(bytes, 4, 'ftyp');
  return RemoteVideoFileDiagnosis(
    isMp4Container: isMp4,
    hasMovieIndex: _containsAscii(bytes, 'moov'),
    hasMediaData: _containsAscii(bytes, 'mdat'),
    videoCodec: _knownVideoCodec(bytes),
  );
}

String remoteVideoFailureMessage(List<int> bytes) {
  final diagnosis = diagnoseRemoteVideoBytes(bytes);
  if (!diagnosis.isMp4Container) {
    return '解密后的内容不是有效的 MP4 文件，文件可能下载不完整或已损坏。';
  }
  if (!diagnosis.isLikelyComplete) {
    return 'MP4 文件头存在，但索引或媒体数据不完整，文件可能下载不完整或已损坏。';
  }
  return '这是完整的 MP4 文件，但视频轨使用 ${diagnosis.codecLabel} 编码，当前设备播放器没有可用的解码器。请先下载原文件，使用系统播放器打开；如仍无法播放，请转换为 H.264 MP4。';
}

String? _knownVideoCodec(List<int> bytes) {
  const codecs = {
    'hvc1',
    'hev1',
    'avc1',
    'avc3',
    'av01',
    'vp09',
    'vp08',
    'mp4v',
  };
  for (var index = 0; index + 4 <= bytes.length; index += 1) {
    final value = String.fromCharCodes(bytes.sublist(index, index + 4));
    if (codecs.contains(value)) {
      return value;
    }
  }
  return null;
}

bool _containsAscii(List<int> bytes, String value) {
  for (var index = 0; index + value.length <= bytes.length; index += 1) {
    if (_asciiAt(bytes, index, value)) {
      return true;
    }
  }
  return false;
}

bool _asciiAt(List<int> bytes, int start, String value) {
  if (start < 0 || start + value.length > bytes.length) {
    return false;
  }
  for (var offset = 0; offset < value.length; offset += 1) {
    if (bytes[start + offset] != value.codeUnitAt(offset)) {
      return false;
    }
  }
  return true;
}

class RemoteFilePreviewResolvedContent {
  final RemoteFilePreviewKind kind;
  final Uint8List bytes;

  const RemoteFilePreviewResolvedContent({
    required this.kind,
    required this.bytes,
  });
}

abstract interface class WechatDatV2ImageKeyProvider {
  Future<WechatDatV2ImageKey?> loadImageKey({
    required String name,
    required String relativePath,
    required List<int> bytes,
  });
}

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

RemoteFilePreviewKind? remoteFilePreviewKindForBytes(List<int> bytes) {
  final signature = detectWechatFileSignature(bytes);
  if (signature == null) {
    final datSignature = detectWechatDatImage(bytes.take(64).toList());
    return datSignature == null ? null : RemoteFilePreviewKind.image;
  }
  return switch (signature.category) {
    'image' => RemoteFilePreviewKind.image,
    'video' => RemoteFilePreviewKind.video,
    'document' when signature.extension == 'pdf' => RemoteFilePreviewKind.pdf,
    _ => null,
  };
}

RemoteFilePreviewResolvedContent? resolveRemoteFilePreviewContent({
  required String name,
  required String relativePath,
  required List<int> bytes,
  WechatDatV2ImageKey? wechatDatV2ImageKey,
}) {
  final hintedKind =
      remoteFilePreviewKindFor(name) ?? remoteFilePreviewKindFor(relativePath);
  if (hintedKind != null) {
    return RemoteFilePreviewResolvedContent(
      kind: hintedKind,
      bytes: Uint8List.fromList(bytes),
    );
  }
  if (wechatDatV2ImageKey != null && looksLikeWechatDatV2Container(bytes)) {
    final decoded = decodeWechatDatV2Image(bytes, wechatDatV2ImageKey);
    if (decoded != null) {
      return RemoteFilePreviewResolvedContent(
        kind: RemoteFilePreviewKind.image,
        bytes: decoded.bytes,
      );
    }
  }
  final contentKind = remoteFilePreviewKindForBytes(bytes);
  if (contentKind == null) {
    return null;
  }
  final datSignature = detectWechatDatImage(bytes.take(64).toList());
  if (datSignature == null) {
    return RemoteFilePreviewResolvedContent(
      kind: contentKind,
      bytes: Uint8List.fromList(bytes),
    );
  }
  return RemoteFilePreviewResolvedContent(
    kind: RemoteFilePreviewKind.image,
    bytes: Uint8List.fromList([
      for (final byte in bytes) byte ^ datSignature.xorKey,
    ]),
  );
}

bool remoteFileCanAttemptPreview(RemoteBackupEntry entry) {
  if (!entry.decryptable ||
      entry.encryptedName.isEmpty ||
      entry.metadataJson.isEmpty) {
    return false;
  }
  if (remoteFilePreviewKindFor(entry.name) != null ||
      remoteFilePreviewKindFor(entry.relativePath) != null) {
    return true;
  }
  return _isWechatProbeCandidate(entry.name, entry.relativePath) &&
      isWechatContentRelativePath(entry.relativePath);
}

bool remoteFileCanProbeContent(RemoteBackupEntry entry) {
  return remoteFileCanAttemptPreview(entry) &&
      remoteFilePreviewKindFor(entry.name) == null &&
      remoteFilePreviewKindFor(entry.relativePath) == null;
}

bool _hasFileExtension(String path) {
  final name = path.replaceAll('\\', '/').split('/').last;
  final dot = name.lastIndexOf('.');
  return dot > 0 && dot < name.length - 1;
}

bool _isWechatProbeCandidate(String name, String relativePath) {
  return _isExtensionlessOrDat(name) && _isExtensionlessOrDat(relativePath);
}

bool _isUnsupportedWechatDatV2Preview({
  required String name,
  required String relativePath,
  required List<int> bytes,
}) {
  return _isWechatProbeCandidate(name, relativePath) &&
      isWechatContentRelativePath(relativePath) &&
      looksLikeWechatDatV2Container(bytes);
}

bool _isExtensionlessOrDat(String path) {
  final normalizedName = path.replaceAll('\\', '/').split('/').last;
  final lowerName = normalizedName.toLowerCase();
  return lowerName.endsWith('.dat') || !_hasFileExtension(normalizedName);
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

const _videoExtensions = {'mp4', 'm4', 'm4v', 'mov', 'webm', 'avi', 'mkv'};

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
  static const _maxProbedBytes = _maxImageBytes;

  final DownloadGateway downloads;
  final DownloadPayloadDecrypter decrypter;
  final WechatDatV2ImageKeyProvider? wechatDatV2ImageKeys;

  const RemoteFilePreviewLoader({
    required this.downloads,
    required this.decrypter,
    this.wechatDatV2ImageKeys,
  });

  @override
  Future<RemoteFilePreviewData> load({
    required String token,
    required RemoteBackupEntry entry,
  }) async {
    if (!entry.decryptable) {
      throw Exception('此文件的元数据无法解密，不能预览');
    }
    final hintedKind =
        remoteFilePreviewKindFor(entry.name) ??
        remoteFilePreviewKindFor(entry.relativePath);
    final shouldProbe = hintedKind == null && remoteFileCanProbeContent(entry);
    if (hintedKind == null && !shouldProbe) {
      throw Exception('暂不支持预览此文件格式');
    }
    final maxBytes = hintedKind == null
        ? _maxProbedBytes
        : _maxBytesFor(hintedKind);
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
    if (resolved == null) {
      if (_isUnsupportedWechatDatV2Preview(
        name: decrypted.name,
        relativePath: decrypted.relativePath,
        bytes: decrypted.bytes,
      )) {
        throw Exception(
          '文件已在服务器备份，但这是微信新版加密 dat 图片，当前无法在线还原为图片。请下载或恢复原文件后，在原微信环境中查看。',
        );
      }
      throw Exception('暂不支持预览此文件格式');
    }
    final resolvedMaxBytes = _maxBytesFor(resolved.kind);
    if (resolved.bytes.length > resolvedMaxBytes) {
      throw Exception('文件过大，在线预览上限为 ${_formatLimit(resolvedMaxBytes)}');
    }
    return RemoteFilePreviewData(
      name: decrypted.name,
      kind: resolved.kind,
      bytes: resolved.bytes,
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
