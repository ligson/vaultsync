import '../../core/network/api_client.dart';
import 'auth_models.dart';

abstract interface class AuthGateway {
  Future<RegisteredUser> register(String email, String password);

  Future<AuthSession> login(String email, String password);

  Future<AuthSession> refresh(String token);

  Future<void> ping();
}

abstract interface class UserProfileGateway {
  Future<UserProfile> loadProfile(String token);

  Future<UserProfile> updateProfile({
    required String token,
    required String username,
    required String nickname,
  });

  Future<void> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  });
}

abstract interface class StorageUsageGateway {
  Future<StorageUsage> loadStorageUsage(String token);
}

abstract interface class AppReleaseGateway {
  Future<AppRelease> loadRelease(String platform);
}

class AuthService
    implements
        AuthGateway,
        UserProfileGateway,
        StorageUsageGateway,
        AppReleaseGateway {
  final ApiClient apiClient;

  const AuthService(this.apiClient);

  @override
  Future<RegisteredUser> register(String email, String password) async {
    final data = await apiClient.post(
      '/api/v1/auth/register',
      body: {'email': email, 'password': password},
    );
    return RegisteredUser.fromJson(data);
  }

  @override
  Future<AuthSession> login(String email, String password) async {
    final data = await apiClient.post(
      '/api/v1/auth/login',
      body: {'email': email, 'password': password},
    );
    return AuthSession.fromJson(data);
  }

  @override
  Future<AuthSession> refresh(String token) async {
    final data = await apiClient.post(
      '/api/v1/auth/refresh',
      body: const {},
      token: token,
    );
    return AuthSession.fromJson(data);
  }

  @override
  Future<void> ping() async {
    await apiClient.ping();
  }

  @override
  Future<UserProfile> loadProfile(String token) async {
    final data = await apiClient.get('/api/v1/auth/me', token: token);
    return UserProfile.fromJson(data);
  }

  @override
  Future<StorageUsage> loadStorageUsage(String token) async {
    final data = await apiClient.get(
      '/api/v1/auth/storage-usage',
      token: token,
    );
    return StorageUsage.fromJson(data);
  }

  @override
  Future<UserProfile> updateProfile({
    required String token,
    required String username,
    required String nickname,
  }) async {
    final data = await apiClient.patch(
      '/api/v1/auth/me',
      token: token,
      body: {'username': username, 'nickname': nickname},
    );
    return UserProfile.fromJson(data);
  }

  @override
  Future<void> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    await apiClient.post(
      '/api/v1/auth/change-password',
      token: token,
      body: {'current_password': currentPassword, 'new_password': newPassword},
    );
  }

  @override
  Future<AppRelease> loadRelease(String platform) async {
    final data = await apiClient.get('/api/v1/releases/$platform');
    return AppRelease.fromJson(data);
  }
}
