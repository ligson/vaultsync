import 'package:flutter/foundation.dart';

class DeviceProfile {
  final String name;
  final String platform;

  const DeviceProfile({required this.name, required this.platform});

  factory DeviceProfile.current() {
    final platform = _platformName(defaultTargetPlatform);
    return DeviceProfile(name: 'VaultSync $platform', platform: platform);
  }

  static String _platformName(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }
}
