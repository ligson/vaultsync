import 'dart:io';

Future<bool> isUsableWechatDirectory(String path) async {
  final directory = Directory(path);
  try {
    if (!await directory.exists()) {
      return false;
    }
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.path.replaceAll('\\', '/').split('/').last;
      if (name == '.drive_sync' || name == '.nomedia') {
        continue;
      }
      return true;
    }
    return false;
  } on FileSystemException {
    return false;
  }
}

Future<bool> _directoryExists(String path) async {
  try {
    return await Directory(path).exists();
  } on FileSystemException {
    return false;
  }
}

abstract interface class WechatFolderDiscoveryGateway {
  Future<WechatFolderDiscoveryResult?> discover(String platform);
}

class WechatFolderDiscoveryResult {
  final String path;
  final bool isPrivateAppDirectory;

  const WechatFolderDiscoveryResult({
    required this.path,
    this.isPrivateAppDirectory = false,
  });
}

/// Finds known WeChat storage roots without recursively searching the device.
///
/// Android OEMs expose different subsets of app storage. Private candidates
/// are therefore probes only: stock Android normally rejects them, while a
/// vendor file-access grant may make them readable.
class LocalWechatFolderDiscovery implements WechatFolderDiscoveryGateway {
  final Map<String, String>? environmentOverride;
  final Future<bool> Function(String path)? directoryExistsOverride;

  const LocalWechatFolderDiscovery({
    Map<String, String>? environment,
    Future<bool> Function(String path)? directoryExists,
  }) : environmentOverride = environment,
       directoryExistsOverride = directoryExists;

  @override
  Future<WechatFolderDiscoveryResult?> discover(String platform) async {
    final desktop =
        platform == 'macos' || platform == 'windows' || platform == 'linux';
    final checkDirectory =
        directoryExistsOverride ??
        (desktop ? _directoryExists : isUsableWechatDirectory);
    for (final candidate in candidatesFor(platform)) {
      if (await checkDirectory(candidate.path)) {
        return candidate;
      }
      // macOS privacy checks can report a known child as unavailable until
      // the user opens it through Finder or the folder picker. Keep the
      // precise WeChat root instead of falling back to its broad parent.
      if (desktop &&
          candidate.path.replaceAll('\\', '/').endsWith('/xwechat_files') &&
          await _directoryExists(Directory(candidate.path).parent.path)) {
        return candidate;
      }
    }
    return null;
  }

  List<WechatFolderDiscoveryResult> candidatesFor(String platform) {
    return switch (platform) {
      'android' => const [
        WechatFolderDiscoveryResult(
          path: '/storage/emulated/0/Android/data/com.tencent.mm/MicroMsg',
          isPrivateAppDirectory: true,
        ),
        WechatFolderDiscoveryResult(
          path: '/storage/emulated/0/Android/data/com.tencent.mm/files',
          isPrivateAppDirectory: true,
        ),
        WechatFolderDiscoveryResult(
          path: '/storage/emulated/0/Pictures/WeiXin',
        ),
        WechatFolderDiscoveryResult(
          path: '/storage/emulated/0/Pictures/WeChat',
        ),
        WechatFolderDiscoveryResult(path: '/storage/emulated/0/DCIM/WeiXin'),
        WechatFolderDiscoveryResult(
          path: '/storage/emulated/0/Tencent/MicroMsg/WeiXin',
        ),
        WechatFolderDiscoveryResult(
          path: '/storage/emulated/0/Download/WeiXin',
        ),
      ],
      'windows' => _windowsCandidates(),
      'macos' => _macosCandidates(),
      _ => const [],
    };
  }

  List<WechatFolderDiscoveryResult> _windowsCandidates() {
    final profile =
        (environmentOverride ?? Platform.environment)['USERPROFILE'] ?? '';
    if (profile.isEmpty) {
      return const [];
    }
    return [
      WechatFolderDiscoveryResult(path: '$profile/Documents/xwechat_files'),
      WechatFolderDiscoveryResult(path: '$profile/Documents/WeChat Files'),
      WechatFolderDiscoveryResult(path: '$profile/Documents/微信文件'),
    ];
  }

  List<WechatFolderDiscoveryResult> _macosCandidates() {
    final home = (environmentOverride ?? Platform.environment)['HOME'] ?? '';
    if (home.isEmpty) {
      return const [];
    }
    const container = 'Library/Containers/com.tencent.xinWeChat/Data';
    return [
      WechatFolderDiscoveryResult(
        path: '$home/$container/Documents/xwechat_files',
      ),
      WechatFolderDiscoveryResult(
        path:
            '$home/$container/Library/Application Support/com.tencent.xinWeChat',
      ),
      WechatFolderDiscoveryResult(path: '$home/$container/Documents'),
      WechatFolderDiscoveryResult(path: '$home/Documents/xwechat_files'),
      WechatFolderDiscoveryResult(path: '$home/Documents/WeChat Files'),
    ];
  }
}
