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

  test(
    'v2 Android key uses stable Android ID instead of build fingerprint',
    () {
      final beforeSystemUpdate = DeviceProfile.stableClientKeyV2('android', [
        '8238b5d3aaf0b045',
        'Solana Mobile Inc.',
        'solanamobile',
        'Seeker',
      ]);
      final afterSystemUpdate = DeviceProfile.stableClientKeyV2('android', [
        '8238b5d3aaf0b045',
        'Solana Mobile Inc.',
        'solanamobile',
        'Seeker',
      ]);

      expect(beforeSystemUpdate, afterSystemUpdate);
      expect(beforeSystemUpdate, startsWith('vaultsync-device:v2:android:'));
    },
  );
}
