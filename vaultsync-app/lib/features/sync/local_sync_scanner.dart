import 'dart:io';
import 'dart:typed_data';

import '../../core/storage/app_storage.dart';
import 'sync_models.dart';
import 'wechat_dat_decoder.dart';

abstract interface class LocalSyncScanGateway {
  Future<List<LocalSyncFile>> scanMappedRoots({String? syncRootId});
}

bool isIgnoredLocalSyncRelativePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/');
  if (segments.any((segment) => segment == '.drive_sync')) {
    return true;
  }
  final fileName = segments.isEmpty ? normalized : segments.last;
  final lowerName = fileName.toLowerCase();
  const temporarySuffixes = <String>{
    '.crdownload',
    '.download',
    '.part',
    '.partial',
    '.tmp',
    '.aria2',
    '.opdownload',
    '.!qb',
  };
  return temporarySuffixes.any(lowerName.endsWith);
}

bool _isIgnoredWechatDirectorySegment(String segment) {
  final lower = segment.toLowerCase();
  const nonUserContentDirectories = {
    'appbrand',
    'card',
    'chatroom_notice',
    'crash',
    'emoji',
    'exdevice',
    'fts',
    'hbstoryvideo',
    'luckymoney',
    'mapsdk',
    'music',
    'openapi',
    'package',
    'recbiz',
    'remark',
    'scanner',
    'scan_product_tmp',
    'textstatus',
    'vusericon',
    'wagamefiles',
    'wallet',
    'wallet_images',
    'web_preload_image',
    'wva',
    'wxacache',
    'wxafiles',
    'wxanewfiles',
    'xlog',
  };
  return lower.startsWith('.') ||
      lower.contains('thumb') ||
      lower.contains('cache') ||
      lower.contains('temp') ||
      nonUserContentDirectories.contains(lower) ||
      lower == 'avatar' ||
      lower.startsWith('head_image') ||
      lower == 'database' ||
      lower == 'db' ||
      lower.startsWith('db_') ||
      lower == 'sqlite' ||
      lower == 'config' ||
      lower == 'log' ||
      lower == 'logs' ||
      lower == 'all_users';
}

class WechatFileSignature {
  final String category;
  final String extension;

  const WechatFileSignature({required this.category, required this.extension});
}

bool _startsWithBytes(List<int> bytes, List<int> signature) {
  if (bytes.length < signature.length) {
    return false;
  }
  for (var index = 0; index < signature.length; index += 1) {
    if (bytes[index] != signature[index]) {
      return false;
    }
  }
  return true;
}

String _asciiSlice(List<int> bytes, int start, int end) {
  if (bytes.length < end) {
    return '';
  }
  return String.fromCharCodes(bytes.sublist(start, end));
}

/// Detects user-facing WeChat files whose on-disk names have no extension.
///
/// This only recognizes standard container signatures. It deliberately does
/// not attempt to decrypt WeChat databases or proprietary WXGF/WXAM payloads.
WechatFileSignature? detectWechatFileSignature(List<int> bytes) {
  if (_startsWithBytes(bytes, const [0xff, 0xd8, 0xff])) {
    return const WechatFileSignature(category: 'image', extension: 'jpg');
  }
  if (_startsWithBytes(bytes, const [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ])) {
    return const WechatFileSignature(category: 'image', extension: 'png');
  }
  final prefix = _asciiSlice(bytes, 0, 6);
  if (prefix == 'GIF87a' || prefix == 'GIF89a') {
    return const WechatFileSignature(category: 'image', extension: 'gif');
  }
  if (_asciiSlice(bytes, 0, 4) == 'RIFF' &&
      _asciiSlice(bytes, 8, 12) == 'WEBP') {
    return const WechatFileSignature(category: 'image', extension: 'webp');
  }
  if (_asciiSlice(bytes, 4, 8) == 'ftyp') {
    final brand = _asciiSlice(bytes, 8, 12).toLowerCase();
    const heifBrands = {
      'heic',
      'heix',
      'hevc',
      'hevx',
      'mif1',
      'msf1',
      'avif',
      'avis',
    };
    if (heifBrands.contains(brand)) {
      return WechatFileSignature(
        category: 'image',
        extension: brand.startsWith('avi') ? 'avif' : 'heic',
      );
    }
    return const WechatFileSignature(category: 'video', extension: 'mp4');
  }
  if (_startsWithBytes(bytes, const [0x25, 0x50, 0x44, 0x46, 0x2d])) {
    return const WechatFileSignature(category: 'document', extension: 'pdf');
  }
  return null;
}

bool _hasFileExtension(String path) {
  final name = path.replaceAll('\\', '/').split('/').last;
  final dot = name.lastIndexOf('.');
  return dot > 0 && dot < name.length - 1;
}

bool _mayHaveMisleadingWechatExtension(String path) {
  final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    return false;
  }
  return const {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'heif',
    'avif',
    'mp4',
    'mov',
    'm4v',
    'dat',
  }.contains(name.substring(dot + 1));
}

String _replaceFileExtension(String path, String extension) {
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  if (dot <= slash || dot == path.length - 1) {
    return '$path.$extension';
  }
  return '${path.substring(0, dot)}.$extension';
}

bool _isWechatContentPath(String path) {
  return isWechatContentRelativePath(path);
}

bool isWechatContentRelativePath(String path) {
  final segments = path
      .replaceAll('\\', '/')
      .split('/')
      .map((segment) => segment.toLowerCase());
  const contentDirectories = {
    'image',
    'image2',
    'video',
    'msgattach',
    'attach',
    'weixin',
    'download',
    'networkfiles',
  };
  return segments.any(contentDirectories.contains);
}

bool _isWechatCategorySelected(String category, String includedFileTypes) {
  final selected = includedFileTypes
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet();
  return selected.isEmpty || selected.contains(category);
}

/// Returns whether a file in a classified source should be uploaded.
///
/// WeChat stores chats, indexes, thumbnails and caches next to user files.
/// Only the user-facing media extensions are included so a backup cannot
/// accidentally copy the app database or transient cache files.
bool shouldIncludeLocalSyncFile(
  String path, {
  String sourceType = 'folder',
  String includedFileTypes = '',
}) {
  // Desktop archive mode keeps the original WeChat account tree, including
  // encrypted databases and files without extensions.
  if (sourceType == 'wechat_archive') {
    return true;
  }
  if (sourceType != 'wechat') {
    return true;
  }
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/');
  if (segments.length > 1 &&
      segments
          .take(segments.length - 1)
          .any(_isIgnoredWechatDirectorySegment)) {
    return false;
  }
  final name = segments.isEmpty ? normalized : segments.last;
  if (name.startsWith('.')) {
    return false;
  }
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    return false;
  }
  final extension = name.substring(dot + 1).toLowerCase();
  const image = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'heif',
    'avif',
    'bmp',
    'tif',
    'tiff',
  };
  const video = {'mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp'};
  const document = {
    'pdf',
    'txt',
    'md',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'csv',
    'rtf',
    'zip',
    'rar',
    '7z',
    'pages',
    'numbers',
    'key',
  };
  final isWechatImageContainer =
      extension == 'dat' &&
      segments.any((segment) {
        final lower = segment.toLowerCase();
        return lower == 'image' ||
            lower == 'image2' ||
            lower == 'msgattach' ||
            lower == 'attach' ||
            lower == 'weixin';
      });
  final category = image.contains(extension) || isWechatImageContainer
      ? 'image'
      : video.contains(extension)
      ? 'video'
      : document.contains(extension)
      ? 'document'
      : '';
  if (category.isEmpty) {
    return false;
  }
  return _isWechatCategorySelected(category, includedFileTypes);
}

class LocalSyncScanner implements LocalSyncScanGateway {
  final SyncRootMappingStore mappings;

  const LocalSyncScanner({required this.mappings});

  @override
  Future<List<LocalSyncFile>> scanMappedRoots({String? syncRootId}) async {
    final rootMappings = await mappings.loadSyncRootMappings();
    final files = <LocalSyncFile>[];
    var processedFileCount = 0;
    for (final mapping in rootMappings) {
      if (syncRootId != null && mapping.syncRootId != syncRootId) {
        continue;
      }
      // Media and virtual sources are scanned by their dedicated gateway.
      if (mapping.localPath.trim().isEmpty) {
        continue;
      }
      final root = Directory(mapping.localPath);
      if (!await root.exists()) {
        continue;
      }
      await for (final entity in _listFiles(root, mapping)) {
        final relativePath = _relativePath(mapping.localPath, entity.path);
        if (isIgnoredLocalSyncRelativePath(relativePath)) {
          continue;
        }
        var effectiveRelativePath = relativePath;
        var shouldInclude = shouldIncludeLocalSyncFile(
          relativePath,
          sourceType: mapping.sourceType,
          includedFileTypes: mapping.includedFileTypes,
        );
        if (!shouldInclude &&
            mapping.sourceType == 'wechat' &&
            !_hasFileExtension(relativePath) &&
            _isWechatContentPath(relativePath)) {
          final signature = await _readWechatFileSignature(entity);
          if (signature != null &&
              _isWechatCategorySelected(
                signature.category,
                mapping.includedFileTypes,
              )) {
            shouldInclude = true;
            effectiveRelativePath = '$relativePath.${signature.extension}';
          }
        }
        if (!shouldInclude) {
          continue;
        }
        if (mapping.sourceType == 'wechat' &&
            _isWechatContentPath(relativePath) &&
            (_mayHaveMisleadingWechatExtension(relativePath) ||
                !_hasFileExtension(relativePath))) {
          final signature = await _readWechatFileSignature(entity);
          if (signature != null &&
              _isWechatCategorySelected(
                signature.category,
                mapping.includedFileTypes,
              )) {
            effectiveRelativePath = _replaceFileExtension(
              relativePath,
              signature.extension,
            );
          }
        }
        final stat = await entity.stat();
        files.add(
          LocalSyncFile(
            syncRootId: mapping.syncRootId,
            localPath: entity.path,
            relativePath: effectiveRelativePath,
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
            encryptionEnabled: mapping.encryptionEnabled,
            sourceType: mapping.sourceType == 'wechat'
                ? 'wechat_file'
                : mapping.sourceType == 'wechat_archive'
                ? 'wechat_archive_file'
                : 'file',
          ),
        );
        processedFileCount += 1;
        if (processedFileCount % 200 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    files.sort((left, right) {
      final rootCompare = left.syncRootId.compareTo(right.syncRootId);
      if (rootCompare != 0) {
        return rootCompare;
      }
      return left.relativePath.compareTo(right.relativePath);
    });
    return files;
  }

  Future<WechatFileSignature?> _readWechatFileSignature(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final bytes = await handle.read(32);
      final raw = detectWechatFileSignature(Uint8List.fromList(bytes));
      if (raw != null) {
        return raw;
      }
      final dat = detectWechatDatImage(bytes);
      return dat == null
          ? null
          : WechatFileSignature(category: 'image', extension: dat.extension);
    } on FileSystemException {
      return null;
    } finally {
      if (handle != null) {
        await handle.close();
      }
    }
  }

  Stream<File> _listFiles(Directory root, LocalSyncRootMapping mapping) async* {
    final pending = <Directory>[root];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      try {
        await for (final entity in directory.list(followLinks: false)) {
          final relativePath = _relativePath(mapping.localPath, entity.path);
          if (entity is Directory) {
            if (!_shouldSkipDirectory(relativePath, mapping.sourceType)) {
              pending.add(entity);
            }
          } else if (entity is File) {
            yield entity;
          }
        }
      } on FileSystemException {
        if (directory.path == root.path) {
          throw Exception('无法访问同步目录：${mapping.localPath}。请确认目录权限后重试');
        }
        // A single protected cache directory must not abort the whole backup.
      }
    }
  }

  bool _shouldSkipDirectory(String relativePath, String sourceType) {
    if (sourceType != 'wechat') {
      return false;
    }
    final segments = relativePath.replaceAll('\\', '/').split('/');
    return segments.any(_isIgnoredWechatDirectorySegment);
  }

  String _relativePath(String rootPath, String filePath) {
    final normalizedRoot = _normalizePath(rootPath);
    final normalizedFile = _normalizePath(filePath);
    if (normalizedFile == normalizedRoot) {
      return '';
    }
    final prefix = normalizedRoot.endsWith('/')
        ? normalizedRoot
        : '$normalizedRoot/';
    if (normalizedFile.startsWith(prefix)) {
      return normalizedFile.substring(prefix.length);
    }
    return normalizedFile.split('/').last;
  }

  String _normalizePath(String path) {
    var normalized = path.replaceAll('\\', '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
