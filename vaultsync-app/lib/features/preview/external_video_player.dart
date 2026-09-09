import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class ExternalVideoPlayer {
  static const _channel = MethodChannel('vaultsync/external_media');
  static const _retention = Duration(days: 3);

  const ExternalVideoPlayer();

  Future<bool> open({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (kIsWeb || !Platform.isAndroid || bytes.isEmpty) {
      return false;
    }
    final temporaryDirectory = await getTemporaryDirectory();
    final directory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}vaultsync-external-media',
    );
    await directory.create(recursive: true);
    await _removeExpiredFiles(directory);

    final file = File(
      '${directory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}${_extensionFor(fileName)}',
    );
    await file.writeAsBytes(bytes, flush: true);
    try {
      return await _channel.invokeMethod<bool>('openExternalMedia', {
            'path': file.path,
            'mimeType': 'video/mp4',
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _removeExpiredFiles(Directory directory) async {
    final expiresAt = DateTime.now().subtract(_retention);
    try {
      await for (final entity in directory.list()) {
        if (entity is! File) {
          continue;
        }
        try {
          if ((await entity.stat()).modified.isBefore(expiresAt)) {
            await entity.delete();
          }
        } catch (_) {
          // Temporary cache cleanup must not block opening the current video.
        }
      }
    } catch (_) {
      // The operating system can clear the temporary directory independently.
    }
  }

  String _extensionFor(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex < 0) {
      return '.mp4';
    }
    final extension = fileName.substring(dotIndex).toLowerCase();
    if (extension == '.m4') {
      return '.mp4';
    }
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.mp4';
  }
}
