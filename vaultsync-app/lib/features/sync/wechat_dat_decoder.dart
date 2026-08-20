import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'encrypted_upload_payload_preparer.dart';
import 'local_upload_executor.dart';
import 'sync_models.dart';

/// The legacy desktop WeChat image container is commonly a byte-wise XOR
/// wrapper around a normal JPEG/PNG/GIF/WebP file. This decoder only accepts a
/// key when the decoded header matches a complete known signature; private
/// WXGF/WXAM data is deliberately left untouched.
class WechatDatImageSignature {
  final String extension;
  final int xorKey;

  const WechatDatImageSignature({
    required this.extension,
    required this.xorKey,
  });
}

WechatDatImageSignature? detectWechatDatImage(List<int> bytes) {
  if (bytes.isEmpty) {
    return null;
  }
  final candidates = <({String extension, List<int> magic})>[
    (extension: 'jpg', magic: const [0xff, 0xd8, 0xff]),
    (
      extension: 'png',
      magic: const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    ),
    (extension: 'gif', magic: const [0x47, 0x49, 0x46, 0x38]),
    (extension: 'webp', magic: const [0x52, 0x49, 0x46, 0x46]),
  ];
  for (final candidate in candidates) {
    if (bytes.length < candidate.magic.length) {
      continue;
    }
    final key = bytes.first ^ candidate.magic.first;
    final decoded = [
      for (var index = 0; index < candidate.magic.length; index += 1)
        bytes[index] ^ key,
    ];
    if (!_startsWith(decoded, candidate.magic)) {
      continue;
    }
    if (candidate.extension == 'webp') {
      if (bytes.length < 12 ||
          !_startsWith(
            [for (var index = 8; index < 12; index += 1) bytes[index] ^ key],
            const [0x57, 0x45, 0x42, 0x50],
          )) {
        continue;
      }
    }
    return WechatDatImageSignature(extension: candidate.extension, xorKey: key);
  }
  return null;
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) {
    return false;
  }
  for (var index = 0; index < prefix.length; index += 1) {
    if (bytes[index] != prefix[index]) {
      return false;
    }
  }
  return true;
}

Future<WechatDatImageSignature?> detectWechatDatImageFile(File source) async {
  RandomAccessFile? handle;
  try {
    handle = await source.open();
    final bytes = await handle.read(64);
    return detectWechatDatImage(bytes);
  } on FileSystemException {
    return null;
  } finally {
    await handle?.close();
  }
}

Future<File?> decodeWechatDatFile({
  required File source,
  required Directory outputDirectory,
}) async {
  final signature = await detectWechatDatImageFile(source);
  if (signature == null) {
    return null;
  }
  final stat = await source.stat();
  final cacheKey = crypto.sha256
      .convert(
        utf8.encode(
          '${source.absolute.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}|${signature.xorKey}',
        ),
      )
      .toString();
  await outputDirectory.create(recursive: true);
  final output = File(
    '${outputDirectory.path}${Platform.pathSeparator}$cacheKey.${signature.extension}',
  );
  if (await output.exists() && await output.length() > 0) {
    return output;
  }
  final part = File('${output.path}.part');
  if (await part.exists()) {
    await part.delete();
  }
  final sink = part.openWrite();
  var offset = 0;
  try {
    await for (final chunk in source.openRead()) {
      sink.add([for (final byte in chunk) byte ^ signature.xorKey]);
      offset += chunk.length;
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  if (offset != stat.size) {
    try {
      await part.delete();
    } catch (_) {
      // The source stability check below still prevents uploading changed data.
    }
    throw const UploadSourceChangedException();
  }
  if (await output.exists()) {
    await output.delete();
  }
  await part.rename(output.path);
  return output;
}

/// Adapts a local upload reader so only legacy, safely decoded `.dat` images
/// are uploaded as real image bytes. Unknown WeChat formats use the original
/// source and therefore remain visible as `.dat` instead of being corrupted.
class WechatDatUploadContentReader
    implements StreamingUploadContentReader, UploadTemporaryFileCleanup {
  final UploadContentReader fileReader;
  final UploadCacheDirectoryProvider? cacheDirectoryProvider;
  final Map<String, File> _temporaryFiles = <String, File>{};

  WechatDatUploadContentReader({
    required this.fileReader,
    this.cacheDirectoryProvider,
  });

  bool _isDat(LocalUploadTask task) {
    return task.sourceType == 'wechat_file' &&
        task.localPath.toLowerCase().endsWith('.dat');
  }

  @override
  Future<List<int>> read(LocalUploadTask task) async {
    final bytes = await fileReader.read(task);
    if (!_isDat(task)) {
      return bytes;
    }
    final signature = detectWechatDatImage(bytes.take(64).toList());
    if (signature == null) {
      return bytes;
    }
    return [for (final byte in bytes) byte ^ signature.xorKey];
  }

  @override
  Future<File?> resolveFile(LocalUploadTask task) async {
    final source = await _resolveUnderlyingFile(task);
    if (source == null || !_isDat(task) || cacheDirectoryProvider == null) {
      return source;
    }
    final decoded = await decodeWechatDatFile(
      source: source,
      outputDirectory: await cacheDirectoryProvider!(),
    );
    if (decoded == null) {
      return source;
    }
    _temporaryFiles[task.id] = decoded;
    return decoded;
  }

  @override
  Future<List<File>> temporaryFilesForCleanup(LocalUploadTask task) async {
    final file = _temporaryFiles.remove(task.id);
    return file == null ? const [] : [file];
  }

  Future<File?> _resolveUnderlyingFile(LocalUploadTask task) async {
    if (fileReader is StreamingUploadContentReader) {
      return (fileReader as StreamingUploadContentReader).resolveFile(task);
    }
    return null;
  }
}
