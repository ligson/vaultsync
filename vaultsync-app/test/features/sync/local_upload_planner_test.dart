import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/sync/local_upload_planner.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('enqueueScannedFiles creates pending upload tasks', () async {
    final store = FakeUploadTaskStore();
    final planner = LocalUploadPlanner(
      uploadTasks: store,
      now: () => DateTime.utc(2026, 6, 27, 10),
    );

    final tasks = await planner.enqueueScannedFiles([
      LocalSyncFile(
        syncRootId: 'root-1',
        localPath: '/Users/alice/Photos/a.jpg',
        relativePath: 'a.jpg',
        sizeBytes: 3,
        modifiedAt: DateTime.utc(2026, 6, 27, 9),
      ),
    ]);

    expect(tasks, hasLength(1));
    expect(tasks.single.id, 'root-1:a.jpg');
    expect(tasks.single.status, 'pending');
    expect(tasks.single.attempts, 0);
    expect(store.saved.single.localPath, '/Users/alice/Photos/a.jpg');
  });

  test('enqueueScannedFiles upserts existing task for same file', () async {
    final store = FakeUploadTaskStore();
    final planner = LocalUploadPlanner(
      uploadTasks: store,
      now: () => DateTime.utc(2026, 6, 27, 10),
    );

    final first = LocalSyncFile(
      syncRootId: 'root-1',
      localPath: '/Users/alice/Photos/a.jpg',
      relativePath: 'a.jpg',
      sizeBytes: 3,
      modifiedAt: DateTime.utc(2026, 6, 27, 9),
    );
    final second = LocalSyncFile(
      syncRootId: 'root-1',
      localPath: '/Users/alice/Photos/a.jpg',
      relativePath: 'a.jpg',
      sizeBytes: 7,
      modifiedAt: DateTime.utc(2026, 6, 27, 9, 30),
    );

    await planner.enqueueScannedFiles([first]);
    await planner.enqueueScannedFiles([second]);

    expect(store.saved, hasLength(1));
    expect(store.saved.single.sizeBytes, 7);
    expect(store.saved.single.modifiedAt, DateTime.utc(2026, 6, 27, 9, 30));
  });

  test(
    'enqueueScannedFiles keeps uploaded status when file is unchanged',
    () async {
      final modifiedAt = DateTime.utc(2026, 6, 27, 9);
      final store = FakeUploadTaskStore([
        LocalUploadTask(
          id: 'root-1:a.jpg',
          syncRootId: 'root-1',
          localPath: '/Users/alice/Photos/a.jpg',
          relativePath: 'a.jpg',
          sizeBytes: 3,
          modifiedAt: modifiedAt,
          status: 'uploaded',
          attempts: 0,
          createdAt: DateTime.utc(2026, 6, 27, 8),
        ),
      ]);
      final planner = LocalUploadPlanner(
        uploadTasks: store,
        now: () => DateTime.utc(2026, 6, 27, 10),
      );

      await planner.enqueueScannedFiles([
        LocalSyncFile(
          syncRootId: 'root-1',
          localPath: '/Users/alice/Photos/a.jpg',
          relativePath: 'a.jpg',
          sizeBytes: 3,
          modifiedAt: modifiedAt,
        ),
      ]);

      expect(store.saved.single.status, 'uploaded');
      expect(store.saved.single.createdAt, DateTime.utc(2026, 6, 27, 8));
    },
  );
}

class FakeUploadTaskStore implements UploadTaskStore {
  final List<LocalUploadTask> saved;

  FakeUploadTaskStore([List<LocalUploadTask>? initial]) : saved = [...?initial];

  @override
  Future<List<LocalUploadTask>> loadUploadTasks() async => saved;

  @override
  Future<void> saveUploadTasks(List<LocalUploadTask> tasks) async {
    saved
      ..clear()
      ..addAll(tasks);
  }
}
