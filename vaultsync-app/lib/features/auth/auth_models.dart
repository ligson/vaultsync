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

  const AuthSession({
    required this.token,
    required this.tokenId,
    required this.userId,
    required this.expiresAt,
  });

  factory AuthSession.fromJson(Map<String, Object?> json) {
    return AuthSession(
      token: json['token'] as String,
      tokenId: json['token_id'] as String,
      userId: json['user_id'] as String,
      expiresAt: json['expires_at'] as String,
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
