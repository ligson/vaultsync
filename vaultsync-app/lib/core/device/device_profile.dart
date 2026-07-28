import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';

class DeviceProfile {
  final String name;
  final String platform;

  const DeviceProfile({required this.name, required this.platform});

  factory DeviceProfile.current() {
    final platform = _platformName(defaultTargetPlatform);
    return DeviceProfile(name: 'VaultSync $platform', platform: platform);
  }

  static Future<DeviceProfile> currentFriendly({
    DeviceInfoPlugin? plugin,
    TargetPlatform? targetPlatform,
  }) async {
    final resolvedPlatform = targetPlatform ?? defaultTargetPlatform;
    final platform = _platformName(resolvedPlatform);
    final deviceInfo = plugin ?? DeviceInfoPlugin();
    try {
      final name = switch (resolvedPlatform) {
        TargetPlatform.android => _androidName(await deviceInfo.androidInfo),
        TargetPlatform.iOS => _iosName(await deviceInfo.iosInfo),
        TargetPlatform.macOS => _macosName(await deviceInfo.macOsInfo),
        TargetPlatform.windows => _windowsName(await deviceInfo.windowsInfo),
        TargetPlatform.linux => _linuxName(await deviceInfo.linuxInfo),
        TargetPlatform.fuchsia => '',
      };
      final normalizedName = _cleanName(name);
      if (normalizedName.isNotEmpty) {
        return DeviceProfile(name: normalizedName, platform: platform);
      }
    } catch (_) {
      // 部分测试环境或未注册平台插件时可能无法读取设备信息，回退到稳定默认名。
    }
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

  static String _androidName(AndroidDeviceInfo info) {
    return _joinUnique([info.manufacturer, info.model]);
  }

  static String _iosName(IosDeviceInfo info) {
    final userName = _cleanName(info.name);
    if (userName.isNotEmpty && userName != info.model) {
      return userName;
    }
    return _joinUnique([info.modelName, info.localizedModel, info.model]);
  }

  static String _macosName(MacOsDeviceInfo info) {
    return _firstNotBlank([info.computerName, info.modelName, info.model]);
  }

  static String _windowsName(WindowsDeviceInfo info) {
    return _firstNotBlank([info.computerName, info.productName]);
  }

  static String _linuxName(LinuxDeviceInfo info) {
    return _firstNotBlank([info.prettyName, info.name]);
  }

  static String _joinUnique(List<String> parts) {
    final normalizedParts = <String>[];
    for (final rawPart in parts) {
      final part = _cleanName(rawPart);
      if (part.isEmpty) {
        continue;
      }
      final alreadyIncluded = normalizedParts.any(
        (existing) =>
            existing.toLowerCase() == part.toLowerCase() ||
            part.toLowerCase().contains(existing.toLowerCase()),
      );
      if (!alreadyIncluded) {
        normalizedParts.add(part);
      }
    }
    return normalizedParts.join(' ');
  }

  static String _firstNotBlank(List<String> values) {
    for (final value in values) {
      final cleaned = _cleanName(value);
      if (cleaned.isNotEmpty) {
        return cleaned;
      }
    }
    return '';
  }

  static String _cleanName(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }
}
