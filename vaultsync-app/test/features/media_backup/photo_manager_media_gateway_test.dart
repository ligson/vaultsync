import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/media_backup/photo_manager_media_gateway.dart';

void main() {
  test('media type filter includes selected image and video types', () {
    expect(PhotoManagerMediaGateway.assetTypeFor('image'), 'image');
    expect(PhotoManagerMediaGateway.assetTypeFor('video'), 'video');
    expect(PhotoManagerMediaGateway.assetTypeFor('image_video'), 'common');
  });

  test(
    'deleteAssets splits more than 2000 assets into system requests',
    () async {
      final batches = <List<String>>[];
      final gateway = PhotoManagerMediaGateway(
        deleteAssets: (assetIds) async {
          batches.add(List<String>.from(assetIds));
          return assetIds;
        },
        assetExists: (_) async => true,
      );
      final ids = List<String>.generate(2248, (index) => 'asset-$index');

      final result = await gateway.deleteAssets(ids);

      expect(batches.map((batch) => batch.length), [500, 500, 500, 500, 248]);
      expect(result.deletedAssetIds, ids.toSet());
      expect(result.message, isEmpty);
    },
  );

  test(
    'deleteAssets keeps completed batches when a later batch fails',
    () async {
      var callCount = 0;
      final gateway = PhotoManagerMediaGateway(
        deleteAssets: (assetIds) async {
          callCount += 1;
          if (callCount == 2) {
            throw Exception('system request failed');
          }
          return assetIds;
        },
        assetExists: (_) async => true,
      );
      final ids = List<String>.generate(2248, (index) => 'asset-$index');

      final result = await gateway.deleteAssets(ids);

      expect(callCount, 2);
      expect(result.deletedAssetIds.length, 500);
      expect(result.deletedAssetIds, ids.take(500).toSet());
      expect(result.message, contains('已清理 500 个'));
    },
  );

  test('deleteAssets stops after a cancelled system batch', () async {
    var callCount = 0;
    final gateway = PhotoManagerMediaGateway(
      deleteAssets: (assetIds) async {
        callCount += 1;
        return callCount == 1 ? assetIds : const <String>[];
      },
      assetExists: (_) async => true,
    );
    final ids = List<String>.generate(4200, (index) => 'asset-$index');

    final result = await gateway.deleteAssets(ids);

    expect(callCount, 2);
    expect(result.deletedAssetIds.length, 500);
    expect(result.message, contains('后续批次已取消'));
  });

  test(
    'deleteAssets removes duplicate and empty asset ids before batching',
    () async {
      final batches = <List<String>>[];
      final gateway = PhotoManagerMediaGateway(
        deleteAssets: (assetIds) async {
          batches.add(List<String>.from(assetIds));
          return assetIds;
        },
        assetExists: (_) async => true,
      );

      final result = await gateway.deleteAssets([
        'asset-1',
        '',
        ' asset-1 ',
        'asset-2',
      ]);

      expect(batches, [
        ['asset-1', 'asset-2'],
      ]);
      expect(result.deletedAssetIds, {'asset-1', 'asset-2'});
    },
  );

  test(
    'deleteAssets treats missing local media assets as already cleaned',
    () async {
      final batches = <List<String>>[];
      final gateway = PhotoManagerMediaGateway(
        deleteAssets: (assetIds) async {
          batches.add(List<String>.from(assetIds));
          return assetIds;
        },
        assetExists: (assetId) async => assetId != 'asset-missing',
      );

      final result = await gateway.deleteAssets([
        'asset-1',
        'asset-missing',
        'asset-2',
      ]);

      expect(batches, [
        ['asset-1', 'asset-2'],
      ]);
      expect(result.deletedAssetIds, {'asset-1', 'asset-missing', 'asset-2'});
      expect(result.message, contains('本地已不存在'));
    },
  );

  test('deleteAssets skips ids when existence lookup fails', () async {
    final batches = <List<String>>[];
    final gateway = PhotoManagerMediaGateway(
      deleteAssets: (assetIds) async {
        batches.add(List<String>.from(assetIds));
        return assetIds;
      },
      assetExists: (assetId) async {
        if (assetId == 'asset-stale') {
          throw Exception('stale media id');
        }
        return true;
      },
    );

    final result = await gateway.deleteAssets(['asset-1', 'asset-stale']);

    expect(batches, [
      ['asset-1'],
    ]);
    expect(result.deletedAssetIds, {'asset-1', 'asset-stale'});
    expect(result.message, contains('本地已不存在'));
  });
}
