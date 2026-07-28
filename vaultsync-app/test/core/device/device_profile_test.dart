import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/device/device_profile.dart';

void main() {
  test('device profile uses readable Android manufacturer and model', () async {
    final plugin = DeviceInfoPlugin.setMockInitialValues(
      androidDeviceInfo: AndroidDeviceInfo.setMockInitialValues(
        version: AndroidBuildVersion.setMockInitialValues(
          codename: 'REL',
          incremental: '1',
          previewSdkInt: 0,
          release: '12',
          sdkInt: 31,
        ),
        board: 'board',
        bootloader: 'bootloader',
        brand: 'HUAWEI',
        device: 'NOH',
        display: 'display',
        fingerprint: 'fingerprint',
        hardware: 'hardware',
        host: 'host',
        id: 'id',
        manufacturer: 'HUAWEI',
        model: 'NOH-AN00',
        product: 'NOH-AN00',
        name: 'NOH-AN00',
        supported32BitAbis: const [],
        supported64BitAbis: const [],
        supportedAbis: const [],
        tags: 'release-keys',
        type: 'user',
        isPhysicalDevice: true,
        freeDiskSize: 1,
        totalDiskSize: 2,
        systemFeatures: const [],
        isLowRamDevice: false,
        physicalRamSize: 8192,
        availableRamSize: 4096,
      ),
    );

    final profile = await DeviceProfile.currentFriendly(
      plugin: plugin,
      targetPlatform: TargetPlatform.android,
    );

    expect(profile.name, 'HUAWEI NOH-AN00');
    expect(profile.platform, 'android');
  });
}
