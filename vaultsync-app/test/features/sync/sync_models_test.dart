import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('LocalUploadTask preserves capturedAt through JSON', () {
    final capturedAt = DateTime.parse('2026-09-01T00:30:00+08:00');
    final task = _task(capturedAt: capturedAt);

    final restored = LocalUploadTask.fromJson(task.toJson());

    expect(restored.capturedAt, capturedAt);
  });

  test('LocalUploadTask remains compatible with JSON without capturedAt', () {
    final json = _task().toJson()..remove('captured_at');

    final restored = LocalUploadTask.fromJson(json);

    expect(restored.capturedAt, isNull);
  });
}

LocalUploadTask _task({DateTime? capturedAt}) {
  return LocalUploadTask(
    id: 'media-root:asset-1',
    syncRootId: 'media-root',
    localPath: '',
    relativePath: 'Camera/2026/09/a.jpg',
    sizeBytes: 3,
    modifiedAt: DateTime.utc(2026, 8, 31, 16, 30),
    status: 'uploaded',
    attempts: 0,
    createdAt: DateTime.utc(2026, 8, 31, 16, 31),
    sourceType: 'media_asset',
    assetId: 'asset-1',
    assetMediaType: 'image',
    capturedAt: capturedAt,
  );
}
