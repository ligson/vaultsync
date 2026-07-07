import '../../core/network/api_client.dart';
import 'auth_models.dart';

abstract interface class AuthGateway {
  Future<RegisteredUser> register(String email, String password);

  Future<AuthSession> login(String email, String password);

  Future<AuthSession> refresh(String token);

  Future<void> ping();
}

class AuthService implements AuthGateway {
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
}
