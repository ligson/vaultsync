import 'auth_models.dart';

class AuthService {
  AuthSession login(String email, String password) {
    return const AuthSession(token: 'local-token');
  }
}
