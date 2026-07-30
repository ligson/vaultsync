import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/device/device_profile.dart';

void main() {
  test('stableClientKey returns stable hash for same device values', () {
    final first = DeviceProfile.stableClientKey('android', [
      'HUAWEI',
      'NOH-AN00',
      'kirin9000',
      'fingerprint-1',
    ]);
    final second = DeviceProfile.stableClientKey('android', [
      ' HUAWEI ',
      'NOH-AN00',
      'kirin9000',
      'fingerprint-1',
    ]);

    expect(first, second);
    expect(first, startsWith('vaultsync-device:v1:android:'));
  });

  test('stableClientKey changes when device values change', () {
    final first = DeviceProfile.stableClientKey('android', [
      'HUAWEI',
      'NOH-AN00',
      'fingerprint-1',
    ]);
    final second = DeviceProfile.stableClientKey('android', [
      'HUAWEI',
      'NOH-AN00',
      'fingerprint-2',
    ]);

    expect(first, isNot(second));
  });
}
