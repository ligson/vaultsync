import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/local_sync_scanner.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test(
    'wechat source includes user files but excludes caches and databases',
    () {
      expect(
        shouldIncludeLocalSyncFile(
          '微信图片/2026/photo.jpg',
          sourceType: 'wechat',
          includedFileTypes: 'image,video,document',
        ),
        isTrue,
      );
      expect(
        shouldIncludeLocalSyncFile(
          '微信图片/cache/thumb.jpg',
          sourceType: 'wechat',
          includedFileTypes: 'image,video,document',
        ),
        isFalse,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'msg.db',
          sourceType: 'wechat',
          includedFileTypes: 'image,video,document',
        ),
        isFalse,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'docs/report.pdf',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
        isFalse,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'Image/2026/photo.dat',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
        isTrue,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'msg/attach/2026-08/photo.dat',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
        isTrue,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'config/system.dat',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
        isFalse,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'db_storage/head_image/avatar.jpg',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
        isFalse,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'account/image/luckymoney/template.jpg',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
        isFalse,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'mapsdk/indoor/map.png',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
        isFalse,
      );
      expect(
        shouldIncludeLocalSyncFile(
          'chatroom_notice/notice.jpg',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
        isFalse,
      );
    },
  );

  test('scanMappedRoots lists files from local sync root mappings', () async {
    final rootDir = await Directory.systemTemp.createTemp('vaultsync_scan_');
    addTearDown(() => rootDir.delete(recursive: true));
    await File('${rootDir.path}/hello.txt').writeAsString('hello');
    await Directory('${rootDir.path}/nested').create();
    await File('${rootDir.path}/nested/photo.jpg').writeAsString('image-bytes');

    final scanner = LocalSyncScanner(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: rootDir.path,
          encryptedPath: 'vaultsync-path:v1:abc',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]),
    );

    final files = await scanner.scanMappedRoots();

    expect(files.map((file) => file.relativePath), [
      'hello.txt',
      'nested/photo.jpg',
    ]);
    expect(files.first.syncRootId, 'root-1');
    expect(files.first.localPath.endsWith('hello.txt'), isTrue);
    expect(files.first.sizeBytes, 5);
  });

  test(
    'scanMappedRoots tags included WeChat files without scanning databases',
    () async {
      final rootDir = await Directory.systemTemp.createTemp(
        'vaultsync_wechat_',
      );
      addTearDown(() => rootDir.delete(recursive: true));
      await File('${rootDir.path}/photo.jpg').writeAsString('image');
      await File('${rootDir.path}/message.db').writeAsString('database');
      await Directory('${rootDir.path}/cache/deep').create(recursive: true);
      await File(
        '${rootDir.path}/cache/deep/ignored.jpg',
      ).writeAsString('cache');

      final scanner = LocalSyncScanner(
        mappings: FakeSyncRootMappingStore([
          LocalSyncRootMapping(
            syncRootId: 'wechat-root',
            localPath: rootDir.path,
            encryptedPath: 'wechat-backup:v1:test',
            cleanupPolicy: 'keep',
            archivePath: '',
            sourceType: 'wechat',
            includedFileTypes: 'image',
          ),
        ]),
      );

      final files = await scanner.scanMappedRoots();

      expect(files.map((file) => file.relativePath), ['photo.jpg']);
      expect(files.single.sourceType, 'wechat_file');
    },
  );

  test(
    'desktop WeChat archive includes encrypted databases and extensionless files',
    () async {
      final rootDir = await Directory.systemTemp.createTemp(
        'vaultsync_wechat_archive_',
      );
      addTearDown(() => rootDir.delete(recursive: true));
      await File(
        '${rootDir.path}/db_storage/message.db',
      ).create(recursive: true);
      await File('${rootDir.path}/message.db-wal').writeAsString('wal');
      await Directory('${rootDir.path}/image').create(recursive: true);
      await File(
        '${rootDir.path}/image/no-extension',
      ).writeAsBytes(const [1, 2, 3]);
      await File('${rootDir.path}/.part').writeAsString('temporary');

      final scanner = LocalSyncScanner(
        mappings: FakeSyncRootMappingStore([
          LocalSyncRootMapping(
            syncRootId: 'wechat-archive-root',
            localPath: rootDir.path,
            encryptedPath: 'wechat-backup:v1:archive-test',
            cleanupPolicy: 'keep',
            archivePath: '',
            sourceType: 'wechat_archive',
          ),
        ]),
      );

      final files = await scanner.scanMappedRoots();

      expect(
        files.map((file) => file.relativePath),
        containsAll(<String>[
          'db_storage/message.db',
          'message.db-wal',
          'image/no-extension',
        ]),
      );
      expect(
        files.every((file) => file.sourceType == 'wechat_archive_file'),
        isTrue,
      );
      expect(files.map((file) => file.relativePath), isNot(contains('.part')));
    },
  );

  test(
    'scanMappedRoots recognizes extensionless WeChat images by header',
    () async {
      final rootDir = await Directory.systemTemp.createTemp(
        'vaultsync_wechat_magic_',
      );
      addTearDown(() => rootDir.delete(recursive: true));
      await Directory('${rootDir.path}/account/image').create(recursive: true);
      final source = File('${rootDir.path}/account/image/abc123');
      await source.writeAsBytes(const [
        0xff,
        0xd8,
        0xff,
        0xe0,
        0x00,
        0x10,
        0x4a,
        0x46,
        0x49,
        0x46,
      ]);
      await File(
        '${rootDir.path}/unknown-binary',
      ).writeAsBytes(const [1, 2, 3]);

      final scanner = LocalSyncScanner(
        mappings: FakeSyncRootMappingStore([
          LocalSyncRootMapping(
            syncRootId: 'wechat-root',
            localPath: rootDir.path,
            encryptedPath: 'wechat-backup:v1:test',
            cleanupPolicy: 'keep',
            archivePath: '',
            sourceType: 'wechat',
            includedFileTypes: 'image',
          ),
        ]),
      );

      final files = await scanner.scanMappedRoots();

      expect(files, hasLength(1));
      expect(files.single.localPath, source.path);
      expect(files.single.relativePath, 'account/image/abc123.jpg');
    },
  );

  test('scanMappedRoots renames legacy XOR WeChat dat images', () async {
    final rootDir = await Directory.systemTemp.createTemp(
      'vaultsync_wechat_dat_',
    );
    addTearDown(() => rootDir.delete(recursive: true));
    final original = const [
      0xff,
      0xd8,
      0xff,
      0xe0,
      0x00,
      0x10,
      0x4a,
      0x46,
      0x49,
      0x46,
      0x00,
    ];
    const xorKey = 0x5a;
    await Directory('${rootDir.path}/image').create(recursive: true);
    await File(
      '${rootDir.path}/image/photo.dat',
    ).writeAsBytes([for (final byte in original) byte ^ xorKey]);
    final scanner = LocalSyncScanner(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'wechat-root',
          localPath: rootDir.path,
          encryptedPath: 'wechat-backup:v1:test',
          cleanupPolicy: 'keep',
          archivePath: '',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
      ]),
    );

    final files = await scanner.scanMappedRoots();

    expect(files, hasLength(1));
    expect(files.single.relativePath, 'image/photo.jpg');
    expect(files.single.localPath, endsWith('image/photo.dat'));
  });

  test('WeChat signature detection distinguishes standard containers', () {
    expect(
      detectWechatFileSignature(const [0xff, 0xd8, 0xff])?.extension,
      'jpg',
    );
    expect(
      detectWechatFileSignature(const [
        0x00,
        0x00,
        0x00,
        0x18,
        0x66,
        0x74,
        0x79,
        0x70,
        0x69,
        0x73,
        0x6f,
        0x6d,
      ])?.category,
      'video',
    );
    expect(detectWechatFileSignature(const [0x77, 0x78, 0x67, 0x66]), isNull);
  });

  test('scanMappedRoots corrects misleading WeChat media extensions', () async {
    final rootDir = await Directory.systemTemp.createTemp(
      'vaultsync_wechat_webp_',
    );
    addTearDown(() => rootDir.delete(recursive: true));
    await Directory('${rootDir.path}/image').create(recursive: true);
    final source = File('${rootDir.path}/image/render.png');
    await source.writeAsBytes(const [
      0x52,
      0x49,
      0x46,
      0x46,
      0x00,
      0x00,
      0x00,
      0x00,
      0x57,
      0x45,
      0x42,
      0x50,
      0x56,
      0x50,
      0x38,
      0x20,
    ]);

    final scanner = LocalSyncScanner(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'wechat-root',
          localPath: rootDir.path,
          encryptedPath: 'wechat-backup:v1:test',
          cleanupPolicy: 'keep',
          archivePath: '',
          sourceType: 'wechat',
          includedFileTypes: 'image',
        ),
      ]),
    );

    final files = await scanner.scanMappedRoots();

    expect(files.single.relativePath, 'image/render.webp');
  });

  test('scanMappedRoots skips missing local paths', () async {
    final scanner = LocalSyncScanner(
      mappings: FakeSyncRootMappingStore(const [
        LocalSyncRootMapping(
          syncRootId: 'root-missing',
          localPath: '/path/that/does/not/exist',
          encryptedPath: 'vaultsync-path:v1:missing',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]),
    );

    final files = await scanner.scanMappedRoots();

    expect(files, isEmpty);
  });

  test('scanMappedRoots can scan one mapped root', () async {
    final firstRoot = await Directory.systemTemp.createTemp(
      'vaultsync_scan_first_',
    );
    final secondRoot = await Directory.systemTemp.createTemp(
      'vaultsync_scan_second_',
    );
    addTearDown(() => firstRoot.delete(recursive: true));
    addTearDown(() => secondRoot.delete(recursive: true));
    await File('${firstRoot.path}/a.txt').writeAsString('a');
    await File('${secondRoot.path}/b.txt').writeAsString('b');

    final scanner = LocalSyncScanner(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: firstRoot.path,
          encryptedPath: 'vaultsync-path:v1:first',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
        LocalSyncRootMapping(
          syncRootId: 'root-2',
          localPath: secondRoot.path,
          encryptedPath: 'vaultsync-path:v1:second',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]),
    );

    final files = await scanner.scanMappedRoots(syncRootId: 'root-2');

    expect(files, hasLength(1));
    expect(files.single.syncRootId, 'root-2');
    expect(files.single.relativePath, 'b.txt');
  });

  test('scanMappedRoots skips third-party sync control directories', () async {
    final rootDir = await Directory.systemTemp.createTemp(
      'vaultsync_scan_ignore_',
    );
    addTearDown(() => rootDir.delete(recursive: true));
    await File('${rootDir.path}/visible.txt').writeAsString('visible');
    await Directory('${rootDir.path}/.drive_sync').create();
    await File('${rootDir.path}/.drive_sync/.id_123').writeAsString('');
    await Directory(
      '${rootDir.path}/nested/.drive_sync',
    ).create(recursive: true);
    await File('${rootDir.path}/nested/.drive_sync/.id_456').writeAsString('');

    final scanner = LocalSyncScanner(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: rootDir.path,
          encryptedPath: 'vaultsync-path:v1:abc',
          cleanupPolicy: 'keep',
          archivePath: '',
        ),
      ]),
    );

    final files = await scanner.scanMappedRoots();

    expect(files.map((file) => file.relativePath), ['visible.txt']);
  });

  test('scanMappedRoots skips incomplete download files', () async {
    final rootDir = await Directory.systemTemp.createTemp(
      'vaultsync_scan_downloads_',
    );
    addTearDown(() => rootDir.delete(recursive: true));
    await File('${rootDir.path}/ready.zip').writeAsString('ready');
    await File('${rootDir.path}/chrome.zip.crdownload').writeAsString('part');
    await File('${rootDir.path}/firefox.zip.part').writeAsString('part');
    await File('${rootDir.path}/safari.zip.download').writeAsString('part');
    await File('${rootDir.path}/torrent.iso.!qB').writeAsString('part');

    final scanner = LocalSyncScanner(
      mappings: FakeSyncRootMappingStore([
        LocalSyncRootMapping(
          syncRootId: 'root-1',
          localPath: rootDir.path,
          encryptedPath: 'vaultsync-path:v1:abc',
          cleanupPolicy: 'delete',
          archivePath: '',
        ),
      ]),
    );

    final files = await scanner.scanMappedRoots();

    expect(files.map((file) => file.relativePath), ['ready.zip']);
  });
}

class FakeSyncRootMappingStore implements SyncRootMappingStore {
  final List<LocalSyncRootMapping> mappings;

  const FakeSyncRootMappingStore(this.mappings);

  @override
  Future<List<LocalSyncRootMapping>> loadSyncRootMappings() async => mappings;

  @override
  Future<void> saveSyncRootMapping(LocalSyncRootMapping mapping) {
    throw UnimplementedError();
  }

  @override
  Future<void> saveSyncRootMappings(List<LocalSyncRootMapping> mappings) {
    throw UnimplementedError();
  }
}
