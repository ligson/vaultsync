import 'dart:io';

import '../../core/storage/app_storage.dart';
import 'sync_models.dart';

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
      final root = Directory(mapping.localPath);
      if (!await root.exists()) {
        continue;
      }
      await for (final entity
          in root.list(recursive: true, followLinks: false).handleError((
            Object error,
          ) {
            if (error is FileSystemException) {
              throw Exception('无法访问同步目录：${mapping.localPath}。请确认目录权限后重试');
            }
            throw error;
          })) {
        if (entity is! File) {
          continue;
        }
        final relativePath = _relativePath(mapping.localPath, entity.path);
        if (isIgnoredLocalSyncRelativePath(relativePath)) {
          continue;
        }
        final stat = await entity.stat();
        files.add(
          LocalSyncFile(
            syncRootId: mapping.syncRootId,
            localPath: entity.path,
            relativePath: relativePath,
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
            encryptionEnabled: mapping.encryptionEnabled,
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
