import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/wechat_folder_discovery.dart';

void main() {
  test('desktop candidates cover current and legacy WeChat locations', () {
    final discovery = LocalWechatFolderDiscovery(
      environment: const {
        'HOME': '/Users/alice',
        'USERPROFILE': r'C:\Users\alice',
      },
    );

    expect(
      discovery.candidatesFor('windows').map((item) => item.path),
      contains(r'C:\Users\alice/Documents/xwechat_files'),
    );
    expect(
      discovery.candidatesFor('macos').map((item) => item.path),
      contains(
        '/Users/alice/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files',
      ),
    );
  });

  test('desktop discovery prefers the precise xwechat_files root', () async {
    const root =
        '/Users/alice/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files';
    final discovery = LocalWechatFolderDiscovery(
      environment: const {'HOME': '/Users/alice'},
      directoryExists: (path) async => path == root,
    );

    final result = await discovery.discover('macos');

    expect(result?.path, root);
  });

  test('android discovery skips unreadable private storage', () async {
    final discovery = LocalWechatFolderDiscovery(
      directoryExists: (path) async =>
          path == '/storage/emulated/0/Pictures/WeiXin',
    );

    final result = await discovery.discover('android');

    expect(result?.path, '/storage/emulated/0/Pictures/WeiXin');
    expect(result?.isPrivateAppDirectory, isFalse);
  });

  test(
    'android discovery uses vendor-readable app directory when available',
    () async {
      final discovery = LocalWechatFolderDiscovery(
        directoryExists: (path) async => path.contains('/Android/data/'),
      );

      final result = await discovery.discover('android');

      expect(result?.path, contains('/Android/data/com.tencent.mm/'));
      expect(result?.isPrivateAppDirectory, isTrue);
    },
  );

  test('discovery ignores a directory that only has sync metadata', () async {
    final emptyPublic = await Directory.systemTemp.createTemp(
      'vaultsync_wechat_empty_',
    );
    addTearDown(() => emptyPublic.delete(recursive: true));
    await Directory('${emptyPublic.path}/.drive_sync').create();

    expect(await isUsableWechatDirectory(emptyPublic.path), isFalse);
  });
}
