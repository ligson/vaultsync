import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

abstract interface class AvatarStore {
  Future<Uint8List?> load(String userId);

  Future<void> save(String userId, Uint8List bytes);
}

class LocalAvatarStore implements AvatarStore {
  const LocalAvatarStore();

  @override
  Future<Uint8List?> load(String userId) async {
    final file = await _file(userId);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsBytes();
  }

  @override
  Future<void> save(String userId, Uint8List bytes) async {
    final file = await _file(userId);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<File> _file(String userId) async {
    final root = await getApplicationSupportDirectory();
    final safeUserId = userId.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
    return File('${root.path}/profile/avatar-$safeUserId');
  }
}
