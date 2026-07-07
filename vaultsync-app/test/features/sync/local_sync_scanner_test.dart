import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/local_sync_scanner.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
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
