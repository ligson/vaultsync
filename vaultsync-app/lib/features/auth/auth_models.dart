class RegisteredUser {
  final String id;
  final String email;

  const RegisteredUser({required this.id, required this.email});

  factory RegisteredUser.fromJson(Map<String, Object?> json) {
    return RegisteredUser(
      id: json['id'] as String,
      email: json['email'] as String,
    );
  }
}

class AuthSession {
  final String token;
  final String tokenId;
  final String userId;
  final String expiresAt;
  final String refreshToken;
  final String refreshExpiresAt;

  const AuthSession({
    required this.token,
    required this.tokenId,
    required this.userId,
    required this.expiresAt,
    this.refreshToken = '',
    this.refreshExpiresAt = '',
  });

  factory AuthSession.fromJson(Map<String, Object?> json) {
    return AuthSession(
      token: json['token'] as String,
      tokenId: json['token_id'] as String,
      userId: json['user_id'] as String,
      expiresAt: json['expires_at'] as String,
      refreshToken: json['refresh_token'] as String? ?? '',
      refreshExpiresAt: json['refresh_expires_at'] as String? ?? '',
    );
  }
}

class UserProfile {
  final String id;
  final String email;
  final String username;
  final String nickname;
  final int quotaBytes;
  final int usedBytes;

  const UserProfile({
    required this.id,
    required this.email,
    this.username = '',
    this.nickname = '',
    required this.quotaBytes,
    required this.usedBytes,
  });

  factory UserProfile.fromJson(Map<String, Object?> json) {
    return UserProfile(
      id: json['id'] as String,
      email: json['email'] as String,
      username: json['username'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      quotaBytes: (json['quota_bytes'] as num).toInt(),
      usedBytes: (json['used_bytes'] as num).toInt(),
    );
  }

  String get effectiveUsername {
    if (username.isNotEmpty) {
      return username;
    }
    return email.split('@').first;
  }

  String get displayName {
    if (nickname.isNotEmpty) {
      return nickname;
    }
    return effectiveUsername;
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'email': email,
      'username': username,
      'nickname': nickname,
      'quota_bytes': quotaBytes,
      'used_bytes': usedBytes,
    };
  }
}

class StorageUsage {
  final int quotaBytes;
  final int usedBytes;
  final List<DeviceStorageUsage> devices;

  const StorageUsage({
    required this.quotaBytes,
    required this.usedBytes,
    this.devices = const [],
  });

  factory StorageUsage.fromJson(Map<String, Object?> json) {
    final devices = json['devices'] as List? ?? const [];
    return StorageUsage(
      quotaBytes: (json['quota_bytes'] as num?)?.toInt() ?? 0,
      usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
      devices: devices
          .map(
            (item) => DeviceStorageUsage.fromJson(
              Map<String, Object?>.from(item as Map),
            ),
          )
          .toList(),
    );
  }
}

class DeviceStorageUsage {
  final String deviceId;
  final String deviceName;
  final String platform;
  final int usedBytes;
  final List<SyncRootStorageUsage> syncRoots;

  const DeviceStorageUsage({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.usedBytes,
    this.syncRoots = const [],
  });

  factory DeviceStorageUsage.fromJson(Map<String, Object?> json) {
    final roots = json['sync_roots'] as List? ?? const [];
    return DeviceStorageUsage(
      deviceId: json['device_id'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
      syncRoots: roots
          .map(
            (item) => SyncRootStorageUsage.fromJson(
              Map<String, Object?>.from(item as Map),
            ),
          )
          .toList(),
    );
  }
}

class SyncRootStorageUsage {
  final String syncRootId;
  final String encryptedPath;
  final int usedBytes;
  final int fileCount;

  const SyncRootStorageUsage({
    required this.syncRootId,
    required this.encryptedPath,
    required this.usedBytes,
    required this.fileCount,
  });

  factory SyncRootStorageUsage.fromJson(Map<String, Object?> json) {
    return SyncRootStorageUsage(
      syncRootId: json['sync_root_id'] as String? ?? '',
      encryptedPath: json['encrypted_path'] as String? ?? '',
      usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
      fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class AppRelease {
  final String platform;
  final String version;
  final String downloadUrl;
  final int sizeBytes;
  final String updatedAt;

  const AppRelease({
    required this.platform,
    required this.version,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.updatedAt,
  });

  factory AppRelease.fromJson(Map<String, Object?> json) {
    return AppRelease(
      platform: json['platform'] as String,
      version: json['version'] as String? ?? '',
      downloadUrl: json['download_url'] as String? ?? '',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      updatedAt: json['updated_at'] as String? ?? '',
    );
  }
}
