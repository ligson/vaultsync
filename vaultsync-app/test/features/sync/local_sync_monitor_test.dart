import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/local_sync_monitor.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('coalesces desktop file events by sync root', () async {
    final root = await Directory.systemTemp.createTemp('vaultsync_watch_');
    addTearDown(() => root.delete(recursive: true));
    final changes = <Set<String>>[];
    final signal = Completer<void>();
    final monitor = LocalSyncMonitor(
      mappings: _FakeMappingStore([
        _mapping('root-1', root.path),
        _mapping('root-2', root.path),
      ]),
      debounceDuration: const Duration(milliseconds: 40),
      enabled: true,
      onChanged: (ids) {
        changes.add(ids);
        if (!signal.isCompleted) {
          signal.complete();
        }
      },
    );
    await monitor.start();
    addTearDown(monitor.stop);

    await File('${root.path}/a.txt').writeAsString('a');
    await File('${root.path}/a.txt').writeAsString('ab');
    await signal.future.timeout(const Duration(seconds: 3));

    expect(changes, hasLength(1));
    expect(changes.single, {'root-1', 'root-2'});
  });

  test('ignores control directory events and stops cleanly', () async {
    final root = await Directory.systemTemp.createTemp('vaultsync_watch_');
    addTearDown(() => root.delete(recursive: true));
    var callbackCount = 0;
    final monitor = LocalSyncMonitor(
      mappings: _FakeMappingStore([_mapping('root-1', root.path)]),
      debounceDuration: const Duration(milliseconds: 20),
      enabled: true,
      onChanged: (_) => callbackCount++,
    );
    await monitor.start();

    final controlDir = Directory('${root.path}/.drive_sync')
      ..createSync(recursive: true);
    await File('${controlDir.path}/state').writeAsString('ignored');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(callbackCount, 0);

    await monitor.stop();
    await File('${root.path}/after-stop.txt').writeAsString('ignored');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(callbackCount, 0);
  });
}

LocalSyncRootMapping _mapping(String id, String path) => LocalSyncRootMapping(
  syncRootId: id,
  localPath: path,
  encryptedPath: 'vaultsync-path:v1:$id',
  cleanupPolicy: 'keep',
  archivePath: '',
);

class _FakeMappingStore implements SyncRootMappingStore {
  final List<LocalSyncRootMapping> items;

  const _FakeMappingStore(this.items);

  @override
  Future<List<LocalSyncRootMapping>> loadSyncRootMappings() async => items;

  @override
  Future<void> saveSyncRootMapping(LocalSyncRootMapping mapping) async {}

  @override
  Future<void> saveSyncRootMappings(
    List<LocalSyncRootMapping> mappings,
  ) async {}
}
