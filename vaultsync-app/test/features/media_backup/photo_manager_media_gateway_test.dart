import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/media_backup/photo_manager_media_gateway.dart';

void main() {
  test('media type filter includes selected image and video types', () {
    expect(PhotoManagerMediaGateway.assetTypeFor('image'), 'image');
    expect(PhotoManagerMediaGateway.assetTypeFor('video'), 'video');
    expect(PhotoManagerMediaGateway.assetTypeFor('image_video'), 'common');
  });
}
